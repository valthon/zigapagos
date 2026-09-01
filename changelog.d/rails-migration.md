### Added

- `zigapagos migrate` now provides an end-to-end Rails presentation migration
  workflow. It detects Rails applications, inventories their presentation
  sources and integrations, statically recovers and classifies routes, and
  emits deterministic `MIGRATION.md` and versioned manifest artifacts. Every
  unsupported or uncertain construct is recorded as a stable blocker or
  answerable finding rather than being silently omitted; `--strict` turns any
  blocker into a non-zero result for CI and agent loops.
- `zigapagos migrate <rails-app> --from rails --target DIR` converts the
  supported ERB subset into a buildable Zigapagos project with content,
  layouts, partials, deterministic assets, islands, configuration, and build
  files. `MIGRATION.decisions.json` records durable operator choices, while
  the versioned `MIGRATION.handoff.json` records what every user-facing route
  became. Exit code 3 means the target was written successfully but still has
  unanswered routes; exit code 0 means every route was migrated, redirected,
  bound to a backend, or explicitly retained or blocked.
- `--backend openapi.json` binds Rails forms, mutating links, JSON routes, and
  sign-in/sign-up journeys to operations from a ZigBase OpenAPI contract.
  Generated islands use `@zigbase/client`, render backend validation errors,
  preserve confirmed redirects, and keep authentication and authorization
  enforcement on the server. Controller authentication guards become explicit
  decisions instead of silently turning protected pages public.
- Portable presentation behavior can become generated islands: structural
  Stimulus controllers, Turbo Frames, literal-props React roots and their
  relative imports, request-backed list and record regions, and literal Turbo
  Stream subscriptions/actions through the ZigBase realtime client. Dynamic or
  ambiguous shapes remain explicit `retain` or `blocked` decisions.
- Handoffs include typed, deterministic parity evidence for migrated pages,
  assets, authentication, allowed and denied mutations, and validation errors.
  Generated Bun and Playwright runners replay those facts against an isolated
  ZigBase instance without booting the source Rails application.
- The Rails migration reference and installable migration skill document the
  supported template, route, asset, backend, interactivity, decision, handoff,
  and parity contracts. Generated JSON Schemas for the presentation manifest
  and handoff are checked against the emitting Zig types and validated against
  real fixture output in CI.

### Changed

- Singular Rails resources now resolve to their plural controllers, matching
  ActionDispatch. Generated TypeScript projects include the runtime JSX types
  and bundler settings needed to type-check copied JavaScript and JSX sources.
  `--runtime-path` still takes precedence, but generated projects fall back to
  `ZIGAPAGOS_RUNTIME_DIR` instead of leaving a package placeholder when that
  installed-runtime path is available.
- A route's discovery `classification` and migration `status` are deliberately
  separate claims: classification describes source evidence, while status says
  what the converter produced after applying decisions. Consumers deciding
  whether a route migrated should read `MIGRATION.handoff.json`.

### Fixed

- Rails discovery retains safe symlinked views and controllers while refusing
  controller links that resolve outside the application, reports malformed or
  locale-mismatched translation documents, ignores commented default-locale
  assignments, honors namespace helper-prefix overrides, and preserves nested
  `fields_for`, block-form links, dynamic assets, and named-yield defaults as
  explicit migration facts.
- Converter gaps are now answerable: block locals inside findings stay owned by
  those findings; dynamic page titles, genuinely unbound locals, unresolved or
  cyclic partials, and route helpers whose arguments cannot form a URL receive
  stable finding ids. Missing `--doctor`, `--backend`, and `--decisions` inputs
  report the flag, path, and operating-system error and exit 1 instead of
  aborting a debug build.

### Known limitations

- Route recovery is static AST analysis and does not boot Rails. Dynamic route
  generation, engine mounts, external route files, arbitrary helpers, dynamic
  layouts, Haml/Slim, and runtime-generated assets are reported for manual
  handling rather than guessed. Only the configured default i18n locale is
  resolved.
- Stimulus conversion is structural rather than Ruby-to-JavaScript method
  transpilation. Nested controllers, unsupported action descriptors, raw-text
  action elements, React `require()` or dynamic imports, and Vue roots require
  manual work. A Turbo Frame with a `src` still needs that same-origin endpoint
  proxied until the migrated site serves equivalent fragment HTML; realtime
  islands dispatch record facts rather than rendering Rails partials as DOM.
- Forms declared in layouts cannot yet be replaced with bound islands, and an
  authentication form reached only through a layout may remain a separate
  backend question. A generated target uses `https://example.com` as its
  `host_url` until the operator supplies the deployment host.
- Parity runners verify observable presentation and API behavior; they do not
  move authorization into browser code. ZigBase collection and consumer rules
  remain the enforcement boundary.
