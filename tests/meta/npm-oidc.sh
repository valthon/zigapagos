#!/usr/bin/env bash
# The npm publish path authenticates with OIDC trusted publishing, and this gate
# pins the shape of the job that does it.
#
# WHY THIS EXISTS. `publish-npm` in release.yml runs on exactly one trigger — a
# `v*` tag push — so nothing in ordinary CI executes it, and a tag cannot be
# un-pushed. Every property it depends on is therefore first *tested* during a
# release, which is the same reasoning behind tests/release/scripts.sh. Two of
# those properties are plain text in a YAML file and are cheap to pin here:
#
#   THE OIDC PERMISSION. Without `id-token: write` GitHub mints no identity for
#   the run and npm has nothing to exchange. The default for this workflow is
#   `contents: read`, so dropping the job-level block does not fail loudly — it
#   fails at the registry, mid-publish, on a tag.
#
#   THE TWO GATING CONDITIONS. A tag publishes only when the repository variable
#   NPM_PUBLISH_ENABLED is 'true', and only on a tag push. Both live in one `if:`
#   expression that nothing else evaluates until a release.
#
# It deliberately does NOT check the npm-version floor that job also enforces:
# that one has a runtime assertion in the job itself, which fails the run before
# anything is uploaded, and a text gate over it would mostly pin the phrasing of
# a shell script rather than a property.
#
# Pure awk and grep over one tracked file: no toolchain, no network, sub-second.
# Picked up by CI's `tests/*/*.sh` glob like everything else here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORKFLOW=.github/workflows/release.yml
JOB=publish-npm

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- The publishing job's block, which both rules below are scoped to ---------
# Job blocks are two-space-indented keys under `jobs:`; the block runs to the next
# key at that indentation. Text-scoped rather than YAML-parsed because the runners
# this executes on are guaranteed bash and git and nothing else — same trade as
# every other gate under tests/meta/.
[ -f "$WORKFLOW" ] || fail "$WORKFLOW does not exist — the release workflow moved or was renamed"

block=$(awk -v job="$JOB" '
$0 == "  " job ":" { inblock = 1; print; next }
inblock && /^  [^[:space:]#]/ { inblock = 0 }   # the next job
inblock && /^[^[:space:]#]/   { inblock = 0 }   # or the next top-level key
inblock { print }
' "$WORKFLOW")

# A renamed or deleted job must be loud: silently having nothing to check is how a
# gate becomes decorative. Renaming it is also not free at the registry — the
# trusted publishers name the WORKFLOW FILE, so a rename there breaks publishing
# outright, and this is the cheapest place to be reminded of that.
[ -n "$block" ] ||
  fail "$WORKFLOW has no '$JOB:' job. If it was renamed, update $0 — and re-read npm/README.md on trusted publishers."

# --- Rule 1: the OIDC permission ----------------------------------------------
grep -qE '^[[:space:]]*id-token:[[:space:]]*write' <<<"$block" || {
  echo "FAIL: the '$JOB' job does not grant 'id-token: write'." >&2
  echo >&2
  echo "  Without it GitHub mints no OIDC identity for the run, so npm has nothing" >&2
  echo "  to exchange for a publish token and --provenance cannot sign anything." >&2
  echo "  The failure would land at the registry, mid-publish, on a tag." >&2
  exit 1
}

# --- Rule 2: the two gating conditions ----------------------------------------
# One `if:` line, so both conditions are checked against the same expression: a
# rule matching them anywhere in the block would be satisfied by two unrelated
# lines. `head -n1` because a step-level `if:` further down is not the gate.
# `|| true` because a job with no `if:` at all is a case this gate REPORTS, and
# under `set -o pipefail` a non-matching grep would otherwise abort the script
# before the report — exiting 1 with no message, which reads as a crash.
condition=$(grep -E '^[[:space:]]*if:' <<<"$block" | head -n1 || true)
[ -n "$condition" ] ||
  fail "the '$JOB' job has no 'if:' — it would publish on every trigger that reaches it"

for required in "github.event_name == 'push'" "vars.NPM_PUBLISH_ENABLED == 'true'"; do
  case "$condition" in
    *"$required"*) ;;
    *)
      echo "FAIL: the '$JOB' job's condition no longer requires ${required}." >&2
      echo "  condition: ${condition#"${condition%%[![:space:]]*}"}" >&2
      echo >&2
      echo "  Both are deliberate: a tag push is the only trigger that may publish," >&2
      echo "  and NPM_PUBLISH_ENABLED is the arming switch that keeps a tag from" >&2
      echo "  reaching the registry until someone turns it on. See npm/README.md." >&2
      exit 1
      ;;
  esac
done

echo "PASS: '$JOB' publishes via OIDC, tag-gated and arming-switch-gated"
