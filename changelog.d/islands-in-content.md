### Added

- Islands can now be embedded directly in `.smd` content, not only in
  layouts: inside a fenced code block whose fence info is `=html` (SuperMD's
  existing validated raw-HTML escape hatch), use the hyphenated
  `<z-island src="…" client:load :props='…'></z-island>` spelling — the
  islands pass treats it identically to `<island>` in a layout (SSR,
  `data-z-props`, the import map, the runtime script, the `tsc` props gate,
  and the dev island-usage manifest all apply unchanged). The hyphen is
  required: superhtml's `.html`-mode validator (used to vet the fence body)
  rejects a non-hyphenated custom element name per the HTML spec, unlike the
  lax `.superhtml` layout mode where `<island>` has always worked. See
  `docs/islands.md`, "Islands in content (`.smd`)".

### Known limitations

- A content-authored `<z-island>` only accepts static props (`:props` Ziggy
  literals and literal `prop-NAME="value"` attributes). `prop-NAME="$page.*"`
  Scripty expressions do **not** resolve in content — Scripty is evaluated by
  SuperHTML at layout render time, and an `=html` fence's body is emitted
  verbatim, never run through SuperHTML's template evaluator. A page-bound
  prop still needs a layout.
