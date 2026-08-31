### Added

- `zigapagos migrate --from rails`: every route-reachable ERB template is now parsed by the Ruby sidecar; the manifest gains `findings[]` (stable ids, choices) naming each fragment a converter would refuse, routes carry their Rails helper `name`, and a controller's literal `layout` declaration is honoured (#167 Stage 1).
- `docs/migration/rails-to-zigapagos.md`: route-name derivation, layout resolution, the `findings[]` shape and its Stage 1 derivation table, and the fragment vocabulary table (the design spec's own table, plus a status column saying what Stage 1 actually does with each kind: classify, or classify-and-finding). Mirrored byte-for-byte into `skills/zigapagos-rails-migration/references/`, and the skill's own procedure gains a step for reading `findings[]`.

### Known limitations

- Findings are questions, not decisions: a finding never affects the exit-code check `blockers[]` drives, and never makes the report or the manifest less trustworthy. What answers one is `MIGRATION.decisions.json`, added by the conversion later in this release, where an unanswered finding on a route is what leaves a `--target` run incomplete.
- `route_id` is `null` on every template- or controller-scoped Stage 1 finding. Later route-scoped findings in this release set it to one affected route while retaining stable finding ids.
- Only the default i18n locale resolves `t()` keys; every other locale is out of scope, not a partial best-effort.
- A singular `resource :x` still derives controller `x`; Rails itself maps a singular resource to the plural controller (`resource :profile` → `ProfilesController`). Pass `controller:` explicitly until this is fixed.
