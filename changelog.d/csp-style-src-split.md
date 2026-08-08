### Changed

- The generated strict-CSP header (`csp.nginx.conf`/`csp.apache.conf`/`csp.zigbase.txt`) now
  emits the CSP3 `style-src-elem`/`style-src-attr` split instead of a blanket
  `style-src 'self' 'unsafe-inline'`. `<style>` elements and `<link>` stylesheets are now hashed
  and governed by `style-src-elem`, exactly as strict as `script-src`; only `style-src-attr` keeps
  `'unsafe-inline'`, confined to the framework's inline `style` *attributes* (`display:contents`
  on island slot wrappers), which CSP hashes cannot cover. Operators who deployed a previously
  generated CSP header must regenerate and redeploy it — the directive name changed, so a stale
  copy no longer matches what the site's HTML needs. Sites relying on the old blanket grant for
  their own inline `<style>` elements (e.g. the `zigapagos init` scaffold layouts) keep working
  automatically: those elements are now hashed rather than allowed by the removed
  `unsafe-inline`. The one case that does NOT survive is a `<style>` element created at RUNTIME by
  client code (a CSS-in-JS library injecting one on hydration): it has no build-time text to hash,
  so `style-src-elem` blocks it where the blanket grant permitted it — ship those as a stylesheet
  asset or as `style` attributes instead (`docs/spa.md`). Fixes #130.

### Security

- Dropped the blanket `style-src 'unsafe-inline'` grant, which permitted inline `<style>`
  *element* injection sitewide to cover something narrower (inline style *attributes*). The new
  `style-src-elem` directive is hash-strict with no `unsafe-inline`; the lenient grant is now
  confined to `style-src-attr` alone.
