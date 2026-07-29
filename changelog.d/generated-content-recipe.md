### Added

- `docs/generated-content.md`: documents the generated-content pattern this site's own
  docs pages use as a copyable recipe (a registry, a deterministic generator, per-file
  `.gitignore` entries, and a freshness gate), instead of a built-in `content_generators`
  config hook. The verdict on #34 is that a hook would only automate the cheap part
  (invoking a script); the actual cost is the five SuperMD transformations a generator has
  to apply, which are documented here in full instead.

### Internal

- Extracted the SuperMD transformer out of `site/scripts/gen-docs-mirror.ts` into
  `site/scripts/md-to-smd.ts`, a repo-agnostic module with no repo-specific constants
  (paths, URLs, or fence-language remaps are all passed in via `TransformOptions`), so it
  is the thing `docs/generated-content.md` tells a reader to copy. Verified byte-identical
  output against the pre-extraction generator across all 9 existing mirrors.
- Templated `site/test/docs-mirror.sh`'s repo-specific paths behind variables at the top,
  and fixed its rendered-HTML directive check, which used to grep the built page for
  a literal Scripty directive with no way to tell a real leak from a directive shown as a
  documented code sample — a false positive `docs/generated-content.md` would have tripped
  immediately. It now strips `<pre>`/`<code>` before matching.
- Added `site/test/md-to-smd.test.ts`, unit tests for the extracted transformer covering
  heading-slug edge cases (the em-dash double-hyphen, dedup, an indented fence), link
  rewriting, the leading-title strip, and the Ziggy frontmatter emitter, wired into
  `site/test/docs-mirror.sh` so CI runs them without a workflow change.
