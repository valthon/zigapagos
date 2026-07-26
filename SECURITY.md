# Security policy

Zigapagos is a build tool plus a development server. Nearly everything it does
runs on a developer's own machine, over source that developer wrote. That makes
its threat model narrow and worth stating explicitly, because a fair amount of
what looks alarming in it is load-bearing behaviour rather than a defect — and
knowing which is which saves you a report and saves the maintainer a reply.

## Supported versions

Pre-1.0, one branch, no backports.

| What | Supported |
| ---- | --------- |
| `main` | Yes. Fixes land here and nowhere else. |
| Any `v0.x` git tag in this repository | No. Those tags are inherited from the upstream project this is forked from and predate the fork; they are not Zigapagos releases. |

There are no published binary releases yet, so you build from source at a commit
you picked and "upgrade" means moving that commit. `zigapagos version` prints a
`git describe` string (e.g. `v0.11.2-dev.19+22ea4a0`); the trailing hash is the
part that actually identifies what you are running, and it is what a report
should cite.

## Reporting a vulnerability

**Do not open a public issue for anything exploitable.**

1. **Preferred — GitHub private vulnerability reporting:**
   <https://github.com/valthon/zigapagos/security/advisories/new>. It is private
   between you and the maintainer, keeps the discussion and the eventual advisory
   in one place, and can request a CVE if the issue warrants one.
   *Maintainer note: this needs Settings → Code security → Private vulnerability
   reporting switched on for that link to work. If you are reading this and it is
   still off, turn it on.*
2. **Fallback, if that form is not available to you:** open a public issue
   containing **no technical detail** — title it `security contact request`, name
   the affected component, stop there — and an advisory will be opened to carry on
   privately. This project publishes no email address, so that is the escalation
   path rather than a mailbox.

Useful in a report: the commit hash, the OS, `zig version` and `bun --version`,
whether it still reproduces on a release build (`zig build --release=fast`,
since the default build is a debug build with extra checks), and the smallest
site directory that triggers it. A repository someone can clone and build beats
a description — with the caveat in the next section about what building a
repository means.

## Response expectations

One unpaid solo maintainer. There is no SLA and it would be dishonest to invent
one. Realistically: an acknowledgement within a week or two, and a fix once the
fix is understood. If four weeks pass with no response at all, escalate by
opening a public issue saying a private report has gone unanswered — still
without the details.

No bug bounty. Fixes ship as commits on `main`; anything that affects people
running the build tooling gets a published GitHub Security Advisory so it turns
up in the usual feeds.

## Threat model

Three trust boundaries. The first one is the one that catches people out.

**1. Your project source is trusted input, and the build executes it.**
Zigapagos does not merely parse your project. The Bun sidecar `import`s and
*runs* your own `.island.tsx` and `.spa.tsx` at build time in order to
server-render them — component bodies, `describe()`, `staticPaths()`. So
building a site is no safer than running a script from that same directory, and
cloning an untrusted repository and building it is the same risk class as
`npm install` on it, for the same reason. This is by design and cannot be fixed
without deleting the feature.

**2. The dev server is a development tool, not a production server.**
`zigapagos` (no command) and `zigapagos dev` bind `localhost:1990` by default.
They implement no authentication, no rate limiting, no TLS, and no hardening
against a hostile client. `--host 0.0.0.0` will happily expose that to your
network; on an untrusted network, don't. `--proxy PREFIX=UPSTREAM` exists
precisely to forward matching requests to a backend you named, credentials
included — that is the feature, and it is why the dev loop can exercise
cookie-auth flows at all. Your built output is served in production by something
else (a real host: ZigBase, nginx, Apache, a CDN), which is where production
hardening belongs.

**3. The output is static files, plus your code.** What your islands and your
SPA do in a visitor's browser is your code, running with whatever privileges
your host grants it.

### In scope — please do report these

- **Escaping the site root.** Path traversal in the dev server's request
  handling, or a `..` in a route, alias, or asset path that causes the build to
  write outside the output directory.
- **Memory-safety defects reachable from *content*.** Content is frequently less
  trusted than code — a docs site takes outside contributions. A crafted `.smd`,
  layout, frontmatter, or asset that causes an out-of-bounds access, a
  use-after-free, or unbounded allocation in the Zig core is a real bug, and the
  interesting one.
- **The dev server serving files outside the output tree**, or `--proxy`
  forwarding to an upstream other than the configured one (rule-parsing
  confusion in `parseProxyRule`).
- **Injection into generated HTML from content-derived data.** Island props go
  into the page as a JSON `<script>` block; the escaping that keeps a `</script>`
  inside a prop from ending that block early lives in `src/islands/pass.zig`. A
  way past it is in scope.
- **Secrets leaking into build output** — anything that copies environment
  variables, a `.env`, or paths from outside the site into an emitted asset, the
  SPA flags block, or the dev island manifest.
- **Dependency-pin integrity** — a `build.zig.zon` or `runtime/bun.lock` entry
  that resolves to content other than what its hash claims.

### Known limitations, already understood

Not vulnerabilities to report, but stated so nobody has to rediscover them:

- **The `zigbase` download verifies integrity, not authenticity.**
  `zigapagos e2e --download-zigbase` fetches a pinned release tarball and checks
  it against the `SHA256SUMS` published *in that same release*, which catches a
  corrupt or truncated download but not a compromised release. Nothing is ever
  downloaded implicitly — the locator prefers `--zigbase=<path>`, then `zigbase`
  on `PATH`, then the cache, and fails with instructions rather than fetching on
  its own.
- **Strict CSP is supported, but the header is yours to deploy and keep in
  sync.** Hydration needs inline scripts (the import map; for SPAs a `mountSpa`
  bootstrap), so a `script-src` without `unsafe-inline` requires their hashes.
  The build computes a sha256 per unique inline script and writes
  `csp.nginx.conf`, `csp.apache.conf` and `csp.zigbase.txt` at the site root for
  any site with islands or SPAs — but nothing forces your host to actually serve
  that header, and a stale hosted copy will break the page, because the hashes
  are byte-exact. Two deliberate looseness decisions, documented in
  `docs/spa.md`: `style-src` keeps `unsafe-inline` (the framework emits inline
  `style` *attributes*, which hashes cannot cover — hashes apply to elements, not
  attributes), and every external origin appearing in a `<link href>` is unioned
  into `style-src` and `font-src`, so a `spa.head` entry widens those two.
  `script-src` is never widened.

### Not vulnerabilities

- "The build runs code from the project I am building." By design — see
  boundary 1.
- The dev server lacking TLS, authentication, or CSRF protection; or
  `--host 0.0.0.0` exposing it. See boundary 2.
- Anything that requires the attacker to already have write access to the site
  source, the build machine, or the toolchain.
- A build that exhausts memory or time on a pathological input you supplied
  yourself.
- Missing security headers in dev-server responses. Your production host sets
  those.
- Vulnerabilities in Zig, Bun, or a third-party dependency — report those to
  their maintainers. Do tell us if a pin here needs to move as a result.
