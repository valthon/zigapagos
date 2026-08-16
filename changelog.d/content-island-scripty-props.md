### Added

- Content-authored `<z-island>` elements can opt into page-bound Scripty
  `prop-NAME="$…"` values with `scripty:props`; resolved props feed both SSR and
  the `--island-props-check` TypeScript gate while unmarked fences stay verbatim.
