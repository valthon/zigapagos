### Added

- `--allow-missing-pages` (`zigapagos release` and the live server; for a `zigapagos dev`
  loop set `allow_missing_pages` in your `build.zig`, since `dev` re-runs your rebuild
  command rather than building the site itself — the tolerance is identical either way,
  so a green dev preview and a CI release agree):
  tolerate a `$link.page`/`$link.sibling`/`$link.sub` (content) or
  `$site.page(...)` (template) reference to a page that doesn't exist YET, instead of
  hard-failing the build. The reference renders as the real, `url_prefix`-aware `href`
  the target page will have once it's written (a 404 until then), and the build log gets
  a warning naming the ref and the computed href instead of a fatal error. This is the
  fix for incremental authoring: previously, adding a navigation link before its target
  page existed broke the *entire* build (one dangling link → zero pages built), which is
  exactly what "site under construction" always looks like.
- `zigapagos languages`: lists every code-fence language registered for syntax
  highlighting.

### Fixed

- An unknown code-fence language (e.g. a typo like ` ```zig++ `) is now a build-log
  WARNING instead of a fatal error. The fence still renders — as escaped, unhighlighted
  text, the same output `enable_treesitter=false` already produces for every language —
  and the warning includes a did-you-mean suggestion when one is available (run
  `zigapagos languages` to see the full registered list).
- A `$link` reference starting with a leading `.` (SuperMD's syntax for "subpage of this
  section") that fails because the current page isn't a section now includes a note
  clarifying that a leading `.` means "subpage of this section", not a relative path, and
  points at `$link.page(...)` for linking a sibling page instead.
- `$link.page('')` — which looks like it should work, because `$site.page('')` accepts an
  empty ref for the homepage — now fails with a note pointing at `$link.site()`, the
  correct builtin for linking to the site's homepage, instead of just SuperMD's bare
  "path is empty".
