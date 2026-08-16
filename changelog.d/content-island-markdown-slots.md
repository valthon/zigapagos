### Added

- Content-authored `<z-island>` elements can receive native SuperMD-rendered
  children and named slots. `markdown-slot="section-id"` supplies `children`;
  `markdown-slot-NAME="section-id"` supplies `slots.NAME`; referenced sections
  are marked with `.attrs('island-slot')`. Their Markdown keeps normal content
  directives, fenced-code validation, and tree-sitter highlighting, while
  missing, unused, or duplicate slot references fail the build instead of
  losing or duplicating content. This completes issue #153's remaining
  authoring gap.
