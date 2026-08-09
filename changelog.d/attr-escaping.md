### Security

- SuperMD directive metadata is now HTML-escaped everywhere it reaches an HTML attribute
  (issue #148). `src/render/html.zig` printed `title`, `alt`, `id`, `attrs` (rendered into
  `class`), `$link.ref(…)` fragments and the code-fence language with `{s}` — raw — so an
  author-supplied value containing `"` closed the attribute it sat in and could open new ones:
  a `title` of `x" onload="alert(1)` became a real `onload` handler on the emitted element.
  Reachable only by whoever writes the content, so self-inflicted on a single-author site, and
  **not** self-inflicted where content authorship is broader than code authorship — a migrated
  site whose frontmatter came from elsewhere, generated or scripted content, or a repo that
  accepts content contributions. Every such value now goes through `HtmlSafe`, which escapes
  `&`, `<`, `>`, `'` and `"`. URLs are unaffected: `href`/`src` are emitted through `printUrl`
  on its own resolution path, which this change does not touch.

### Fixed

- The same defect, without any malice required: a directive `title` or an image `alt`
  containing a plain double quote — `He said "hi"` — terminated the attribute early and emitted
  malformed HTML. Both now render as `&quot;`.

### Internal

- `tests/rendering/attr-escaping.sh` pins the whole class per attribute name rather than per
  call site, so one directive arm regressing cannot hide behind another still passing, and was
  verified to fail against the pre-fix renderer. Its fixture uses Markdown's angle-bracket
  destination form (`[text](<$directive…>)`): a bare destination ends at the first double
  quote, so a quote-carrying payload would not parse as a directive at all and the test would
  have proved nothing.
