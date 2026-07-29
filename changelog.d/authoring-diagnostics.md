### Changed

- `:else` is now a build error. SuperHTML validates it at parse time and then never
  evaluates it — the renderer null-unwraps its (mandatorily absent) value, so no template
  using `:else` has ever rendered. The error names the fix: write the negated condition on
  a second `<ctx>`, `<ctx :if="$cond">…</ctx><ctx :if="$cond.not()">…</ctx>`.
- `:if` / `:loop` on an element with no end tag — a void element like `<img>`, `<br>`,
  `<input>`, or a self-closing `<item/>` in an `.xml` alternative layout — is now a build
  error. SuperHTML restarts a conditional or a loop by rewinding to the element's end tag;
  with none it rewinds to the start of the file and splices the **whole raw template
  source** into the page (previously with exit code 0), or slices backwards and panics.
  The error names the fix: wrap the element in `<ctx>`.

### Fixed

- The migration guide now spells out the three separate `:if` traps, including the one
  that is still legal and still surprising: `:if` on a real element gates only its BODY,
  so the tag and **every one of its attributes** are emitted either way (this is how a
  documentation sidebar shipped `aria-current="page"` on all 14 nav items with a green
  build). Wrap the element in `<ctx>` to make the element itself conditional.
