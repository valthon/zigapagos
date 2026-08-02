#!/usr/bin/env bash
# Populate Zig's content-addressed package cache from translate-c's GitHub
# mirror when Codeberg is unavailable, then finish resolving the dependency
# graph. This is an opt-in outage escape hatch; normal builds should not need it.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

warm_only_env=""
case "$#" in
  0) ;;
  2)
    if [ "$1" != "--warm-only-env" ] || [ -z "$2" ]; then
      echo "usage: scripts/rescue-codeberg.sh [--warm-only-env <github-env-file>]" >&2
      exit 2
    fi
    warm_only_env="$2"
    ;;
  *)
    echo "usage: scripts/rescue-codeberg.sh [--warm-only-env <github-env-file>]" >&2
    exit 2
    ;;
esac

retry_delay="${RESCUE_RETRY_DELAY_SECONDS:-10}"
case "$retry_delay" in
  ''|*[!0-9]*) echo "error: RESCUE_RETRY_DELAY_SECONDS must be a non-negative integer" >&2; exit 2 ;;
esac

derive_pin() {
  local file="$1" dependency="$2"
  awk -v dependency="$dependency" '
    $0 ~ "^[[:space:]]*\\." dependency "[[:space:]]*=" { in_dependency = 1 }
    in_dependency && $0 ~ /\.url[[:space:]]*=/ {
      url = $0
      sub(/^[^"]*"/, "", url)
      sub(/".*/, "", url)
    }
    in_dependency && $0 ~ /\.hash[[:space:]]*=/ {
      hash = $0
      sub(/^[^"]*"/, "", hash)
      sub(/".*/, "", hash)
    }
    in_dependency && /^[[:space:]]*},/ { exit }
    END {
      if (url == "" || hash == "") exit 1
      printf "%s\t%s", url, hash
    }
  ' "$file" || {
    echo "error: could not derive '$dependency' pin from $file" >&2
    return 1
  }
}

translate_c_mirror() {
  case "$1" in
    git+https://codeberg.org/ziglang/translate-c\#?*|git+https://codeberg.org/ziglang/translate-c\?ref=?*\#?*)
      printf '%s\n' "${1/codeberg.org/github.com}"
      ;;
    git+https://github.com/ziglang/translate-c\#?*|git+https://github.com/ziglang/translate-c\?ref=?*\#?*)
      printf '%s\n' "$1"
      ;;
    *)
      echo "error: refusing unexpected translate-c source: $1" >&2
      return 1
      ;;
  esac
}

fetch_exact() {
  local url="$1" expected="$2" actual="" attempt
  for attempt in 1 2 3; do
    if actual="$(zig fetch "$url")" && [ "$actual" = "$expected" ]; then
      return 0
    fi
    if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
      echo "error: content hash mismatch for $url" >&2
      echo "       expected $expected" >&2
      echo "       got      $actual" >&2
      return 1
    fi
    if [ "$attempt" -eq 3 ]; then
      echo "error: failed to fetch $expected after $attempt attempts" >&2
      return 1
    fi
    sleep "$retry_delay"
  done
}

root_pin="$(derive_pin build.zig.zon translate_c)"
IFS=$'\t' read -r root_url root_hash <<< "$root_pin"
root_mirror_url="$(translate_c_mirror "$root_url")"

# SuperMD is itself on GitHub. Fetch its exact root pin first, then derive its
# transitive translate-c pin from the materialized manifest rather than copying
# a URL or hash into this script.
supermd_pin="$(derive_pin build.zig.zon supermd)"
IFS=$'\t' read -r supermd_url supermd_hash <<< "$supermd_pin"
fetch_exact "$supermd_url" "$supermd_hash"

supermd_zon="zig-pkg/$supermd_hash/build.zig.zon"
[ -f "$supermd_zon" ] || {
  echo "error: zig fetch did not materialize SuperMD at $supermd_zon" >&2
  exit 1
}
transitive_pin="$(derive_pin "$supermd_zon" translate_c)"
IFS=$'\t' read -r transitive_url transitive_hash <<< "$transitive_pin"
transitive_mirror_url="$(translate_c_mirror "$transitive_url")"

echo "warming exact translate-c packages from GitHub..."
fetch_exact "$root_mirror_url" "$root_hash"
fetch_exact "$transitive_mirror_url" "$transitive_hash"

if [ -n "$warm_only_env" ]; then
  printf 'WARMED_TRANSLATE_C_HASHES=%s %s\n' "$root_hash" "$transitive_hash" >> "$warm_only_env"
  exit 0
fi

for attempt in 1 2 3; do
  if zig build --fetch; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "error: dependency resolution failed after $attempt attempts" >&2
    exit 1
  fi
  echo "dependency resolution attempt $attempt failed; retrying..." >&2
  sleep "$retry_delay"
done

for expected in "$root_hash" "$transitive_hash"; do
  found=0
  grep -qF ".hash = \"$expected\"" build.zig.zon && found=1
  if [ "$found" -eq 0 ]; then
    while IFS= read -r zon; do
      if grep -qF ".hash = \"$expected\"" "$zon"; then
        found=1
        break
      fi
    done < <(find zig-pkg -type f -name build.zig.zon)
  fi
  if [ "$found" -eq 0 ]; then
    echo "error: warmed hash is absent from the resolved dependency graph: $expected" >&2
    exit 1
  fi
done

echo "Codeberg rescue complete. Retry your normal zig build command."
