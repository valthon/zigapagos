### Changed

- **The bundled live server is no longer deprecated, and `zigapagos serve` now
  starts it.** It is the zero-setup preview server: an in-memory build with live
  reload that needs nothing but the binary — which is what makes it the first
  command a new site runs, and why `init` points at it. `zigapagos dev` remains
  the recommended loop for a site with a backend (real release tree, real
  same-origin `/api` from ZigBase), and every place that called the preview
  server deprecated now says which loop to use when instead. Previously
  `zigapagos serve` — the spelling the documentation has used throughout —
  printed the help menu and exited 1. The published npm package READMEs teach
  the `serve` spelling too, so the packaged docs and the repository docs agree.
