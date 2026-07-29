### Fixed

- The docs-mirror transformer (`site/scripts/md-to-smd.ts`) tracked fenced code blocks by
  toggling a boolean on any line that was exactly three backticks (or tildes) followed by a
  bare `[A-Za-z0-9_-]*` language. A doc that shows fenced Markdown nests a three-backtick
  block inside a four-backtick one, and SuperMD's own raw-HTML escape hatch is the fence info
  string `=html` — neither is that shape, so the inner closing fence was read as an opener and
  the tracker stayed inverted for the rest of the file, silently dropping every
  `$heading.id(...)` and every link rewrite after it. `docs/islands.md` hit this, and the two
  links whose targets had lost their ids then failed the site build with `unknown ref`. Fence
  recognition now follows CommonMark: a run of three OR MORE delimiters, an arbitrary info
  string (with no backtick in a backtick fence's), and a closer that must match the opener's
  character, be at least as long, and carry no info string.
