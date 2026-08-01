### Internal

- `site/scripts/md-to-smd.ts` no longer rewrites link targets inside **inline** code spans.
  It already left fenced blocks alone, but a link-shaped string between backticks in a
  paragraph was rewritten like a real link — silently, in both directions: a published
  target became a `$link.page(...)` directive the author never wrote, and an unpublished one
  became a bare GitHub URL with no marker at all. The second row was live on this site's own
  changelog page, where a sentence about the `![](…)` content directives published a link to
  `https://github.com/valthon/zigapagos/blob/main/…`. Spans are now split per CommonMark (a
  run of N backticks closes on the next run of exactly N) and only the prose between them is
  rewritten; `slugifyHeading` unwraps spans the same way, so a multi-backtick span in a
  heading no longer leaves its padding spaces behind as an extra hyphen in the anchor (#66).
- A fence language is looked up in `fenceLangRemap` with `Object.hasOwn` rather than a raw
  index, so a fence tagged `constructor`, `toString`, `valueOf`, `hasOwnProperty` or
  `__proto__` is a miss instead of resolving through `Object.prototype` and splicing a
  stringified function into the mirror's language slot. The module is documented as
  copy-me code taking a caller-supplied table, and the caller supplying it is exactly the
  person who cannot see the lookup (#67).
