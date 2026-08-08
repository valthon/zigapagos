#!/usr/bin/env bash
# Hermetic behavioral tests for scripts/rescue-codeberg.sh. The fake `zig`
# materializes SuperMD exactly as the real `zig fetch` does, so no forge or
# package cache is involved in this suite.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/rescue-codeberg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

# The root manifest deliberately carries NO translate_c entry: the build graph
# reaches translate-c only transitively through SuperMD, and the rescue script
# must work from that shape alone (deriving a root pin is what broke when the
# unconsumed root entry was deleted). The optional argument varies SuperMD's
# transitive translate-c URL — the lever for the fails-closed cases below.
make_fixture() {
  local dir="$1" transitive_url="${2:-git+https://codeberg.org/ziglang/translate-c?ref=zig-0.16.x#transitive-commit}"
  mkdir -p "$dir/scripts" "$dir/bin"
  cp "$SCRIPT" "$dir/scripts/"
  cat > "$dir/build.zig.zon" <<'EOF'
.{
    .dependencies = .{
        .supermd = .{
            .url = "git+https://github.com/kristoff-it/supermd#supermd-commit",
            .hash = "supermd-test-hash",
        },
    },
}
EOF
  cat > "$dir/bin/zig" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\$FAKE_ZIG_LOG"
if [ "\${1-}" = fetch ]; then
  case "\$2" in
    git+https://github.com/kristoff-it/supermd#supermd-commit)
      mkdir -p zig-pkg/supermd-test-hash
      cat > zig-pkg/supermd-test-hash/build.zig.zon <<'ZON'
.{
    .dependencies = .{
        .translate_c = .{
            .url = "$transitive_url",
            .hash = "translate_c-transitive-test-hash",
        },
    },
}
ZON
      printf '%s\n' supermd-test-hash
      ;;
    git+https://github.com/ziglang/translate-c?ref=zig-0.16.x#transitive-commit)
      printf '%s\n' "\${FAKE_TRANSITIVE_RESULT:-translate_c-transitive-test-hash}"
      ;;
    *) echo "unexpected fetch: \$2" >&2; exit 9 ;;
  esac
elif [ "\$*" = "build --fetch" ]; then
  attempts=0
  [ ! -f "\$FAKE_ATTEMPTS" ] || attempts="\$(cat "\$FAKE_ATTEMPTS")"
  attempts=\$((attempts + 1))
  printf '%s\n' "\$attempts" > "\$FAKE_ATTEMPTS"
  [ "\$attempts" -gt "\${FAKE_BUILD_FAILURES:-0}" ]
else
  echo "unexpected zig command: \$*" >&2
  exit 9
fi
EOF
  chmod +x "$dir/bin/zig" "$dir/scripts/rescue-codeberg.sh"
}

run_rescue() {
  local dir="$1"
  : > "$dir/zig.log"
  rm -f "$dir/attempts"
  PATH="$dir/bin:$PATH" \
    FAKE_ZIG_LOG="$dir/zig.log" \
    FAKE_ATTEMPTS="$dir/attempts" \
    RESCUE_RETRY_DELAY_SECONDS=0 \
    "$dir/scripts/rescue-codeberg.sh"
}

expect_success() {
  local name="$1" dir="$2"
  if run_rescue "$dir" >/dev/null 2>&1; then
    echo "ok   — $name"
  else
    echo "FAIL — $name" >&2
    failures=$((failures + 1))
  fi
}

expect_log_line() {
  local name="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file"; then
    echo "ok   — $name"
  else
    echo "FAIL — $name" >&2
    failures=$((failures + 1))
  fi
}

make_fixture "$TMP/success"
expect_success "derives and warms the transitive mirror pin without a root entry" "$TMP/success"
if grep -qF 'fetch git+https://codeberg.org/' "$TMP/success/zig.log"; then
  echo "FAIL — rescue contacted Codeberg" >&2
  failures=$((failures + 1))
else
  echo "ok   — rescue never contacts Codeberg"
fi
expect_log_line \
  "transitive translate-c pin uses the GitHub mirror" \
  'fetch git+https://github.com/ziglang/translate-c?ref=zig-0.16.x#transitive-commit' \
  "$TMP/success/zig.log"

make_fixture "$TMP/warm-only"
: > "$TMP/warm-only/github-env"
PATH="$TMP/warm-only/bin:$PATH" \
  FAKE_ZIG_LOG="$TMP/warm-only/zig.log" \
  FAKE_ATTEMPTS="$TMP/warm-only/attempts" \
  RESCUE_RETRY_DELAY_SECONDS=0 \
  "$TMP/warm-only/scripts/rescue-codeberg.sh" \
  --warm-only-env "$TMP/warm-only/github-env" >/dev/null
if [ ! -e "$TMP/warm-only/attempts" ] \
  && grep -qF 'WARMED_TRANSLATE_C_HASHES=translate_c-transitive-test-hash' "$TMP/warm-only/github-env"; then
  echo "ok   — CI mode warms pins without resolving dependencies"
else
  echo "FAIL — CI warm-only mode violated its contract" >&2
  failures=$((failures + 1))
fi

make_fixture "$TMP/retry"
if FAKE_BUILD_FAILURES=2 run_rescue "$TMP/retry" >/dev/null 2>&1 \
  && [ "$(cat "$TMP/retry/attempts")" = 3 ]; then
  echo "ok   — dependency resolution retries transient failures"
else
  echo "FAIL — dependency resolution did not retry exactly twice" >&2
  failures=$((failures + 1))
fi

make_fixture "$TMP/mismatch"
if FAKE_TRANSITIVE_RESULT=wrong-hash run_rescue "$TMP/mismatch" >/dev/null 2>&1; then
  echo "FAIL — mirror hash mismatch was accepted" >&2
  failures=$((failures + 1))
else
  echo "ok   — mirror hash mismatch fails closed"
fi

make_fixture "$TMP/host" 'git+https://example.invalid/ziglang/translate-c#transitive-commit'
if run_rescue "$TMP/host" >/dev/null 2>&1; then
  echo "FAIL — unexpected translate-c source was accepted" >&2
  failures=$((failures + 1))
else
  echo "ok   — unexpected translate-c source fails closed"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "PASS: Codeberg rescue script"
