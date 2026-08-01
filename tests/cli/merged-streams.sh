#!/usr/bin/env bash
# Regression test: a CLI report written to stdout must not overwrite what the
# same command already wrote to stderr when both are redirected to ONE file
# (issue #78).
#
# The defect: the report goes through a BUFFERED `std.Io.Writer` over stdout,
# flushed once at the very end, built by `Io.File.writer` -- which Zig 0.16
# documents as POSITIONAL ("the global seek position is not affected"). The
# Debug-build banner and every `log`/diagnostic line go to stderr via
# unbuffered `std.debug.print`, immediately, as streaming writes that DO
# advance the shared position. With `cmd >f 2>&1` both descriptors share one
# open file description, so the late positional flush writes from ITS own
# offset -- zero -- landing on top of the bytes stderr already committed. The
# output is not interleaved; it is overwritten, silently, and anything parsing
# the structured stdout of a command whose stderr was merged got corrupt input.
#
# The check is a byte-count identity plus a line-survival check, run against
# three commands (`explain`, `doctor`, `validate`) because the four report
# writers are separate call sites and a fix applied to one proves nothing about
# the others:
#
#   (1) merged size == separate stdout size + separate stderr size. An
#       overwrite makes the merged file SHORTER than the sum -- the bytes are
#       not lost from the file, they are written over.
#   (2) every line of both ground-truth captures survives verbatim in the
#       merged file. Size alone could be satisfied by any garbage of the right
#       length; this pins the actual content.
#
# The ground-truth capture is also what makes the test non-vacuous: if a
# command wrote nothing to stderr there would be nothing to clobber, so the
# empty-stderr case is a hard failure rather than a silent pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"
mkdir -p "$SITE/content/docs" "$SITE/layouts/templates"

cat >"$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Merged Streams Fixture",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF

cat >"$SITE/layouts/templates/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title :text="$site.title"></title></head>
<body id="body">
  <super>
</body>
</html>
EOF

cat >"$SITE/layouts/page.shtml" <<'EOF'
<extend template="base.shtml">
<body id="body">
  <div :html="$page.content()"></div>
</body>
EOF

cat >"$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home page, linking to [docs]($link.sub('docs')).
EOF

cat >"$SITE/content/docs/index.smd" <<'EOF'
---
.title = "Docs",
.layout = "page.shtml",
---
Docs index.
EOF

OUT="$WORK/out"
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/release.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/release.log"; fail "the fixture's 'zigapagos release' failed"; }

# Runs one command TWICE with identical arguments: once with the two streams
# captured separately (ground truth), once with them merged into one file the
# way `cmd >f 2>&1` does. Both runs redirect to a real FILE on purpose -- a
# terminal or a pipe is not seekable, so the positional writer silently falls
# back to streaming there and the defect cannot appear.
check() { # $1 = tag, $2 = cwd, remaining = argv
  local tag="$1" dir="$2"; shift 2
  set +e
  ( cd "$dir" && "$ZIGAPAGOS" "$@" ) >"$WORK/$tag.out" 2>"$WORK/$tag.err"
  local rc_split=$?
  ( cd "$dir" && "$ZIGAPAGOS" "$@" ) >"$WORK/$tag.merged" 2>&1
  local rc_merged=$?
  set -e

  [[ "$rc_split" -eq "$rc_merged" ]] \
    || fail "($tag) the two runs exited differently ($rc_split vs $rc_merged) -- not comparable"

  local n_out n_err n_merged
  n_out=$(stat -c%s "$WORK/$tag.out")
  n_err=$(stat -c%s "$WORK/$tag.err")
  n_merged=$(stat -c%s "$WORK/$tag.merged")

  [[ "$n_out" -gt 0 ]] || fail "($tag) wrote nothing to stdout -- this command cannot exercise the defect"
  [[ "$n_err" -gt 0 ]] || fail "($tag) wrote nothing to stderr -- nothing to clobber, so this check would be vacuous (a Debug build's banner normally guarantees it)"

  # (1) the byte-count identity
  [[ "$n_merged" -eq $((n_out + n_err)) ]] || {
    echo "--- merged (first 20 lines) ---"; sed -n '1,20p' "$WORK/$tag.merged"
    fail "($tag) merged file is $n_merged bytes, expected $((n_out + n_err)) (stdout $n_out + stderr $n_err) -- one stream overwrote the other"
  }

  # (2) every ground-truth line survives verbatim
  local missing=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qxF -- "$line" "$WORK/$tag.merged" || { echo "  missing: $line"; missing=$((missing + 1)); }
  done < <(cat "$WORK/$tag.out" "$WORK/$tag.err")
  [[ "$missing" -eq 0 ]] || fail "($tag) $missing line(s) of the separately-captured output are corrupted or absent from the merged file"

  echo "PASS ($tag): stdout ($n_out B) and stderr ($n_err B) both survive intact in one merged file"
}

# `explain` -- a multi-KB structured report; the command issue #78 was filed
# from, and the one whose shell test had to work around this.
check explain "$SITE" explain /docs/

# `doctor` -- the second command the issue reproduces with. Different file,
# different report writer, same construction.
check doctor "$SITE" doctor "$OUT"

# `validate` -- a ONE-LINE report. Worth its own leg: a short stdout write
# overwrites only the first line of stderr, which is the shape of this bug
# most likely to be dismissed as a cosmetic glitch.
check validate "$SITE" validate

# `migrate --doctor` -- the fourth report writer. It is a different subcommand
# with its own file and its own renderers, so leaving it out would mean three
# call sites pinned and one taken on trust.
cat >"$SITE/Counter.island.tsx" <<'TSX'
import { useState } from "react";
export default function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}
TSX
check migrate-doctor "$SITE" migrate --doctor Counter.island.tsx

echo "PASS: merged stdout+stderr is never overwritten (issue #78)"
