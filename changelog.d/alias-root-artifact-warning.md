### Added

- A relative `.aliases` entry that basenames as `404.html`, `robots.txt`, or `sitemap.xml`
  now prints a build-time warning showing where it actually resolves. Alias resolution
  itself is unchanged — a relative entry still joins to the page's own output directory,
  exactly as before; this only flags the common mistake of meaning a site-wide override
  (e.g. `"/404.html"` to replace the SPA fallback) but writing the bare relative form
  instead.
