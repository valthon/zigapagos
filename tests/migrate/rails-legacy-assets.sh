#!/usr/bin/env bash
# End-to-end contract for the Sprockets half of assets.zig's `resolveViaManifest`.
#
# tests/migrate/rails.sh's fixture (rails-sample) is Propshaft-only -- the
# only "sprockets" string anywhere in that fixture tree is a COMMENTED-OUT
# gem, present only to prove commented gems are not detected. So the
# Sprockets branch of resolveViaManifest -- the one that finds and reads a
# REAL compiled `public/assets/manifest-<hex>.json` -- has unit tests but had
# never run through the actual `zigapagos migrate` pipeline end to end. This
# script is that run.
#
# The fixture (rails-legacy-assets) is deliberately the smallest app that
# exercises it for real: a Gemfile declaring sprockets-rails (no propshaft,
# so `detectPipeline` has a single, unambiguous verdict), a compiled
# Sprockets manifest under public/assets/, and exactly two assets --
# `app/assets/images/logo.png`, which the manifest DOES list, and
# `app/assets/stylesheets/application.css.scss`, a preprocessed asset which
# it does NOT (a real Sprockets manifest keys its "assets" object by the
# COMPILED name, "stylesheets/application.css" -- never the ERB/Sass source
# filename with its own preprocessor extension still attached, so a
# preprocessed source is realistically absent from its own manifest entry).
# The two assets discriminate resolveViaManifest's two live outcomes in one
# run: a listed asset resolves to its digested URL as a FACT
# (deterministic: true), and an unlisted one reports `public_url: null`,
# `deterministic: false`, plus a RAILS_ASSET_DIGEST_UNAVAILABLE blocker --
# never a guessed URL for either.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
# Route discovery spawns the Ruby sidecar under runtime/sidecar/rails --
# without this the fixture's one route degrades to RAILS_SIDECAR_MISSING
# before `ruby` on PATH is even checked. See rails.sh's identical note.
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

fail() { echo "FAIL: $*"; exit 1; }
if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build || fail "zig build failed"
fi

RAILS_VALIDATE="$REPO/zig-out/bin/rails_manifest_validate"
if [[ ! -x "$RAILS_VALIDATE" ]]; then
  mise exec -- zig build rails-manifest-validate || fail "zig build rails-manifest-validate failed"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
cp -R "$REPO/tests/migrate/rails-legacy-assets" "$APP"

# --- source immutability -----------------------------------------------------
before="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"

set +e
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/one.md" >"$WORK/one.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || {
  cat "$WORK/one.out"
  fail "migrate exited $rc on the Sprockets fixture -- degradation must stay exit 0 here (no integrity blocker, --strict not passed)"
}

after="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"
[[ "$before" == "$after" ]] || fail "migrate modified the read-only Sprockets fixture"

MANIFEST="$WORK/one.manifest.json"
[[ -f "$MANIFEST" ]] || fail "no manifest written beside the report"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

"$RAILS_VALIDATE" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" \
  || fail "manifest failed schema validation"

# --- pipeline: the Gemfile (sprockets-rails, no propshaft) must resolve to
# the sprockets branch, not propshaft -- this is what makes the rest of this
# script actually exercise resolveViaManifest's Sprockets half. -------------
pipeline_name=$(jq -r '.integrations[] | select(.name == "sprockets" or .name == "propshaft") | .name' "$MANIFEST")
[[ "$pipeline_name" == "sprockets" ]] || fail "expected the sprockets integration to be detected, got: $pipeline_name"

asset_count=$(jq '.assets | length' "$MANIFEST")
[[ "$asset_count" -eq 3 ]] || fail "expected 3 assets (app/assets/images/logo.png, app/assets/stylesheets/application.css.scss, public/assets/manifest-*.json), got: $asset_count"

for a in $(jq -r '.assets[].pipeline // "null"' "$MANIFEST" | grep -v '^null$' | sort -u); do
  [[ "$a" == "sprockets" ]] || fail "an app/assets/-rooted asset resolved against pipeline '$a', expected sprockets"
done

# --- the LISTED asset: a fact, not a guess ----------------------------------
# The manifest fixture lists "images/logo.png" ->
# "images/logo-9f86d081884c7d659a2feaa0c55ad015.png" under its "assets" key
# (Sprockets' own nesting -- see assets.zig's manifestLookup doc). A resolver
# that ignored the manifest and derived a digest itself would also produce
# SOME url here; the exact byte-for-byte match against the fixture's own
# manifest value is what rules that out.
logo_deterministic=$(jq -r '.assets[] | select(.source == "app/assets/images/logo.png") | .deterministic' "$MANIFEST")
[[ "$logo_deterministic" == "true" ]] || fail "logo.png (listed in the compiled manifest) should be deterministic, got: $logo_deterministic"
logo_url=$(jq -r '.assets[] | select(.source == "app/assets/images/logo.png") | .public_url' "$MANIFEST")
[[ "$logo_url" == "/assets/images/logo-9f86d081884c7d659a2feaa0c55ad015.png" ]] \
  || fail "logo.png's public_url should be read verbatim from the manifest, got: $logo_url"

# --- the UNLISTED asset: public_url null, deterministic false, a named
# blocker -- never a smoothed-over 404. --------------------------------------
css_deterministic=$(jq -r '.assets[] | select(.source == "app/assets/stylesheets/application.css.scss") | .deterministic' "$MANIFEST")
[[ "$css_deterministic" == "false" ]] || fail "application.css.scss (not listed under its own source name) should be non-deterministic, got: $css_deterministic"
css_url=$(jq -r '.assets[] | select(.source == "app/assets/stylesheets/application.css.scss") | .public_url' "$MANIFEST")
[[ "$css_url" == "null" ]] || fail "application.css.scss's public_url should be null, got: $css_url"

css_blocker_code=$(jq -r '.blockers[] | select(.source.file == "app/assets/stylesheets/application.css.scss") | .code' "$MANIFEST")
[[ "$css_blocker_code" == "RAILS_ASSET_DIGEST_UNAVAILABLE" ]] \
  || fail "expected RAILS_ASSET_DIGEST_UNAVAILABLE on the unlisted asset, got: $css_blocker_code"
css_blocker_severity=$(jq -r '.blockers[] | select(.source.file == "app/assets/stylesheets/application.css.scss") | .severity' "$MANIFEST")
[[ "$css_blocker_severity" == "warn" ]] || fail "expected the digest-unavailable blocker to be warn severity, got: $css_blocker_severity"
css_blocker_integrity=$(jq -r '.blockers[] | select(.source.file == "app/assets/stylesheets/application.css.scss") | .integrity' "$MANIFEST")
[[ "$css_blocker_integrity" == "false" ]] || fail "the digest-unavailable blocker is not an integrity blocker, got: $css_blocker_integrity"
css_blocker_message=$(jq -r '.blockers[] | select(.source.file == "app/assets/stylesheets/application.css.scss") | .message' "$MANIFEST")
[[ "$css_blocker_message" == *"not listed"* ]] || fail "blocker message should say the asset is not listed, got: $css_blocker_message"

# Exactly one blocker total: the listed asset and the public/-rooted
# manifest file itself (bypasses the pipeline entirely, resolved verbatim)
# must not ALSO produce one.
blocker_count=$(jq '.blockers | length' "$MANIFEST")
[[ "$blocker_count" -eq 1 ]] || fail "expected exactly 1 blocker (the unlisted asset only), got: $blocker_count"

# --- determinism: two runs against the same read-only source produce
# byte-identical manifests. ---------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/two.md" >/dev/null 2>&1 \
  || fail "second migrate run failed"
diff -u "$WORK/one.manifest.json" "$WORK/two.manifest.json" || fail "manifest is not deterministic"

echo "OK: tests/migrate/rails-legacy-assets.sh"
