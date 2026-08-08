### Added

- Cache-Control host config (issue #133): `zigapagos release` now writes a site-wide caching
  policy at the output root alongside the routing and CSP artifacts — `cache.nginx.conf`,
  `cache.apache.conf` and `cache.zigbase.txt`, emitted for every site (island-only sites with
  no SPA namespace included). nginx's `map $uri $zigapagos_cache_control { … }` merges into
  `http{}` with `add_header Cache-Control $zigapagos_cache_control always;` in the *same*
  block that carries `csp.nginx.conf`'s header (a nested `add_header` suppresses the
  server-level one); Apache's `<FilesMatch>` stanzas install where `csp.apache.conf` does.
  Documented in `docs/spa.md`.
- The policy is two header values with `no-cache` as the baseline, so nothing the build emits
  ships header-less: `public, max-age=31536000, immutable` for `asset_fingerprint`'s
  `<stem>.<8 hex>[.<ext>]` name shape and for this build's content-hashed SPA lazy-route
  chunks (exact-listed from each namespace's `routing-manifest.json`, never pattern-matched —
  a naive chunk regex would also swallow stable paths like `<name>-runtime.js`); `no-cache`
  for `*.html`, routing manifests, and every stable path whose URL survives a deploy while its
  content does not. Header-less is not "no caching" but *unspecified* caching (heuristic
  freshness, CDN extension-keyed TTLs) — i.e. fresh HTML paired with a stale entry bundle —
  and `no-cache` still permits a 304, so the cost is one conditional request. Revalidating
  rules always outrank immutable ones, encoded per target's match semantics (nginx `map` is
  first-match-wins, Apache `Header set` is last-match-wins), so hand-merging the stanzas in a
  different order is the one way to break it.
- `cache.zigbase.txt` is advisory, the same stance as `csp.zigbase.txt`: ZigBase has no
  per-path response-header configuration, so the file records the ideal policy for a CDN or
  reverse proxy in front of it, and warns against pointing ZigBase's one *global* knob
  (`--static-cache-control`) at the immutable value — that would cache a stale shell and HTML
  across deploys. Stock `zigbase serve` already sends `max-age=3600` + ETag revalidation for
  static files and `no-cache` for fallback shells.

### Known limitations

- Two documented gaps in the emitted policy, both falling back to the revalidating baseline
  rather than to a wrong header: shared (non-lazy-route) split chunks and `.map` sourcemaps
  are not tracked per-route by the routing manifests, so they cannot be exact-listed as
  immutable; and the fingerprint rule is a name-shape heuristic, not proof `asset_fingerprint`
  is on — the emitter runs over a finished output tree with no site config, so a
  coincidentally fingerprint-shaped filename is marked immutable too. Both artifacts say so
  and show how to drop the line.
