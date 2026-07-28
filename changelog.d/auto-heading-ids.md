### Added

- Opt-in `auto_heading_ids` site setting (`Site`/`MultilingualSite` in `zigapagos.ziggy`):
  injects a GitHub-compatible slug `id` into every heading that doesn't already carry an
  explicit `$heading.id(...)`/`$section.id(...)`, so a same-page `#anchor` or cross-page
  `/page#anchor` link written against a doc's existing GitHub rendering keeps working
  without hand-writing an id on every heading. Off by default; an explicit id always wins
  and is never overwritten. See `docs/migration/astro-to-zigapagos.md`'s "Heading anchors:
  `auto_heading_ids`" section.

### Known limitations

- With `auto_heading_ids` on, a same-page reference through the `$link.ref('slug')` Scripty
  directive still fails with `unknown ref` — SuperMD's own `invalid_ref` check runs inside
  `Ast.init`, before ids can be injected. Plain Markdown links (`[t](#slug)`,
  `[t](/other#slug)`) are validated later and work fine; `$link.unsafeRef('slug')` is the
  workaround for the Scripty-directive case.
