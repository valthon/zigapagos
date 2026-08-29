### Added

- `zigapagos migrate --from rails`: every route-reachable ERB template is now parsed by the Ruby sidecar; the manifest gains `findings[]` (stable ids, choices) naming each fragment a converter would refuse, routes carry their Rails helper `name`, and a controller's literal `layout` declaration is honoured (#167 Stage 1).
- `docs/migration/rails-to-zigapagos.md`: route-name derivation, layout resolution, the `findings[]` shape and its Stage 1 derivation table, and the fragment vocabulary table (the design spec's own table, plus a status column saying what Stage 1 actually does with each kind: classify, or classify-and-finding). Mirrored byte-for-byte into `skills/zigapagos-rails-migration/references/`, and the skill's own procedure gains a step for reading `findings[]`.

### Known limitations

- Findings are questions, not decisions: nothing in this release turns a finding's `choices` (or a classified route) into actual zigapagos content, an island, or a `.spa.tsx`. That is #167 Stage 2, which will also add the `MIGRATION.decisions.json` input a finding's answer is recorded into.
- `route_id` is always `null` on every Stage 1 finding — a finding is scoped to a template or a controller file, not yet joined to the specific route(s) that reach it.
- Only the default i18n locale resolves `t()` keys; every other locale is out of scope, not a partial best-effort.
- A singular `resource :x` still derives controller `x`; Rails itself maps a singular resource to the plural controller (`resource :profile` → `ProfilesController`). Pass `controller:` explicitly until this is fixed.
