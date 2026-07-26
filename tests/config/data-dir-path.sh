#!/usr/bin/env bash
# Regression test: `data_dir_path` is validated like every other config directory,
# and the data dir is watchable-by-absence (a site without one still runs).
#
# The defect this pins: content_dir_path, assets_dir_path, layouts_dir_path,
# i18n_dir_path, url_path_prefix and every locale path went through
# validatePathMessage; `data_dir_path` went through nothing. Because
# Build.loadSiteData opens it with `base_dir.openDir(io, path, ...)` and POSIX
# openat IGNORES the dirfd for an absolute path, this was readable:
#
#   .data_dir_path = "/etc"                    -> reads .ziggy files from /etc
#   .data_dir_path = "../../elsewhere/data"    -> climbs out of the project
#
# and every value landed in `$site.data(...)`, i.e. exposed to every layout --
# while the identical spelling in content_dir_path was a fatal config error.
#
# Phase (3) guards the fix to the fix: the data dir is now WATCHED by serve/dev,
# but `data_dir_path` defaults to "data" whether or not the site has one, and
# dev.zig fatals on an inaccessible watch dir. Watching it unconditionally would
# therefore have broken every site without a data/ dir -- so a release for a
# data-dir-less site must keep working, and a real data dir must still be read.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A fixture whose zigapagos.ziggy carries an extra `.data_dir_path` line.
# $1 = dir to create, $2 = the data_dir_path value (empty => omit the field).
new_site() {
  local site="$1" data_path="${2-}"
  mkdir -p "$site"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$site/"
  if [[ -n "$data_path" ]]; then
    # Insert the field before the closing brace of the Site literal.
    python3 - "$site/zigapagos.ziggy" "tests/rendering/simple/zigapagos.ziggy" "$data_path" <<'PY'
import sys
dst, src, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().rstrip()
assert text.endswith("}"), "fixture zigapagos.ziggy is not a brace-terminated literal"
open(dst, "w").write(text[:-1] + '    .data_dir_path = "%s",\n}\n' % val)
PY
  else
    cp tests/rendering/simple/zigapagos.ziggy "$site/"
  fi
}

# Run a release; echoes the exit code, log goes to $WORK/<tag>.log
release() {
  local tag="$1" site="$2"
  set +e
  ( cd "$site" && "$ZIGAPAGOS" release "--output=$WORK/out-$tag" --force ) >"$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

# --- (1) a traversing data_dir_path must be a fatal config error --------------
for bad in "../escape" "/etc" "data/../.."; do
  tag="bad-$(echo "$bad" | tr -c 'a-zA-Z0-9' '-')"
  SITE="$WORK/$tag"
  new_site "$SITE" "$bad"
  RC="$(release "$tag" "$SITE")"
  [[ "$RC" -ne 0 ]] || {
    echo "--- output ---"; sed -n '1,15p' "$WORK/$tag.log"
    fail "data_dir_path='$bad' was ACCEPTED (exit 0) -- it can read outside the project"
  }
  # It must fail as a *path validation* error, not by accidentally not finding files.
  grep -qiE "path .*in zigapagos.ziggy|data_dir_path" "$WORK/$tag.log" \
    || { echo "--- output ---"; sed -n '1,15p' "$WORK/$tag.log"
         fail "data_dir_path='$bad' failed, but not with a config-path diagnostic"; }
  echo "rejected data_dir_path='$bad' (exit $RC)"
done

# --- (2) an ordinary relative data_dir_path with real data still works --------
SITE_OK="$WORK/ok"
new_site "$SITE_OK" "data"
mkdir -p "$SITE_OK/data"
printf '{\n    .greeting = "hello-from-data",\n}\n' > "$SITE_OK/data/main.ziggy"
RC="$(release "ok" "$SITE_OK")"
[[ "$RC" -eq 0 ]] || {
  echo "--- output ---"; sed -n '1,20p' "$WORK/ok.log"
  fail "a normal relative data_dir_path with a real data dir failed to build"
}
echo "accepted data_dir_path='data' with a real data dir"

# --- (3) a site with NO data dir must still build ----------------------------
# Guards the existence-gating of the new serve/dev data-dir watch: data_dir_path
# defaults to "data" even when the directory does not exist, and treating that as
# an error (or as an unwatchable watch dir) would break every such site.
SITE_NODATA="$WORK/nodata"
new_site "$SITE_NODATA"            # no .data_dir_path field, no data/ directory
[[ ! -d "$SITE_NODATA/data" ]] || fail "test bug: the no-data fixture has a data dir"
RC="$(release "nodata" "$SITE_NODATA")"
[[ "$RC" -eq 0 ]] || {
  echo "--- output ---"; sed -n '1,20p' "$WORK/nodata.log"
  fail "a site with no data/ directory failed to build -- a missing data dir must mean 'no data', not an error"
}
echo "site with no data/ directory builds fine"

echo "PASS: data_dir_path is validated like every other config path, and a missing data dir is not an error"
