#!/usr/bin/env bash
# CI dependency-pin gate: no workflow step may resolve an npm package at run
# time without an explicit version pin (#50).
#
# WHY THIS EXISTS. Everything else this repository depends on is pinned or
# vendored: mise.toml pins zig and bun to exact versions, every `bun install` in
# CI passes --frozen-lockfile, and the Zig dependency tree is materialized under
# zig-pkg/ from hashes in build.zig.zon. Against that, one `bunx serve` in a
# workflow — which resolves and downloads whatever the registry serves at the
# moment the job runs — is both a reproducibility hole (a green run and a red
# one can differ by nothing that is in this repository) and a supply-chain
# surface (an npm package this project never chose a version of, executing on a
# runner with a checkout). It was the last one, and the point of this gate is
# that it stays the last one.
#
# It is also not hypothetical as a FAILURE mode, not just a risk: `bunx serve -l
# 8080` was observed ignoring the requested port and binding a random one,
# which presents as a browser job timing out against a site that is up.
#
# WHAT COUNTS. A package RUNNER — `npx`, `bunx`, `bun x`, `pnpm dlx`, `yarn
# dlx` — on a non-comment line of a tracked workflow, unless that line carries
# an explicit `@<version>`. Pinning is allowed rather than banned outright
# because a pinned runner is a legitimate way to use a one-shot tool; what is
# not legitimate is leaving the version to whenever the job happens to run.
#
# KNOWN GAP, stated rather than glossed. browser-e2e.yml installs Playwright
# with an unpinned `pip install playwright`, and this gate does not look at pip.
# That is deliberate, not an oversight: the same step then runs `playwright
# install --with-deps chrome`, which installs whatever Google Chrome STABLE is
# that day. The browser is a floating channel by design — it is the thing those
# helpers are meant to be tested against — so pinning the driver that launches
# it would buy reproducibility for the smaller half of the pair and cost a bump
# process. If Chrome is ever pinned, pin Playwright in the same change and widen
# this gate then.
#
# Pure `git ls-files` + awk over tracked text: no toolchain, no network,
# sub-second. Picked up by CI's `tests/*/*.sh` glob like everything else here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mapfile -t WORKFLOWS < <(git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort)

# Anti-vacuity. A gate whose input set silently became empty prints PASS forever;
# tests/meta/script-coverage.sh's header records two assertions that rotted that
# way. If the workflows move, this must go red rather than quiet.
if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "FAIL: no tracked workflow files under .github/workflows/ — the path or the layout changed" >&2
  exit 1
fi

# Comment lines are skipped, and that is load-bearing rather than tidy: the very
# workflow this gate was written for now carries a comment NAMING the runner it
# no longer calls, to explain why. Without the skip the gate would fail on its
# own rationale. `#`-first works for both syntaxes involved — a YAML comment and
# a shell comment inside a `run: |` block are spelled the same way.
#
# THE PIN CHECK IS LINE-SCOPED, not token-scoped: a line carrying a runner is
# exempt if anything on it looks like `@<version>`. Walking the tokens to find
# the package spec past arbitrary flags (`npx --yes -p a b`) is more parser than
# this warrants, and the direction of the imprecision is the safe one — a false
# NEGATIVE on a contrived line that pairs a bare runner with an unrelated
# version, never a false positive on a real invocation. If that line is ever
# written, the fix is to pin the runner, which is what the gate wanted anyway.
hits=$(awk '
/^[[:space:]]*#/ { next }
{
  if (match($0, /(^|[^[:alnum:]_.\/-])(npx|bunx|(bun|pnpm|yarn)[[:space:]]+(x|dlx))([[:space:]]|$)/)) {
    if ($0 ~ /@[v^~]?[0-9]/) next
    printf "%s:%d:%s\n", FILENAME, FNR, $0
  }
}
' "${WORKFLOWS[@]}")

if [ -n "$hits" ]; then
  echo "FAIL: unpinned npm package runner(s) in CI:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo >&2
  echo "  Pin the version (\`bunx serve@14.2.4\`), or use something already on the" >&2
  echo "  runner. See the header of $0 for why a runtime resolve is not acceptable" >&2
  echo "  in a repository that pins its toolchain and vendors its dependencies." >&2
  exit 1
fi

echo "PASS: ${#WORKFLOWS[@]} workflow(s) — no unpinned package runners"
