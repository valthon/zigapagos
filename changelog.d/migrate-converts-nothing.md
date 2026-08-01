### Changed

- `zigapagos migrate --help` now states outright that the command converts
  nothing: it reads the Astro project, writes a `MIGRATION.md` worklist, and
  the port itself is manual — `--scaffold` being the one exception, and only
  for islands. The README bullet and the site's overview page said or implied
  otherwise.
