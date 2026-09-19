# Check a static deployment

Compare a running local or staging host with the release tree you intend to
publish. This is a developer-side HTTP check: the deployed server only serves
files and headers, and needs no Bun, Node, or frontend build toolchain.

From a Zigapagos checkout:

```sh
bun runtime/scripts/check-static-deploy.ts \
  --site ./public --url http://127.0.0.1:8080/ --json
```

With the npm CLI installed in your project, the script is at
`node_modules/@zigapagos/cli/runtime/scripts/check-static-deploy.ts`.
Start your chosen static host separately, serving the completed release tree.
Apply its generated route, CSP, and cache configuration first; see
[SPA deployment](spa.md#deploy-targets). The checker never changes server settings,
starts a production server, or uploads files.

For a subpath deployment, give the mount URL:

```sh
bun runtime/scripts/check-static-deploy.ts \
  --site ./public --url http://127.0.0.1:8080/preview/
```

Build for that same `url_path_prefix`. The output directory itself does not
contain a `preview/` subdirectory. Every SPA manifest must agree with the URL's
mount; a mismatch fails before any requests. Static-only trees have no manifest
prefix to compare, so the supplied mount determines their request URLs.

## What it checks

- Every `.html`, `.css`, `.js`, and `.mjs` file is fetched and compared byte for
  byte with the local release, with the expected MIME type. `index.html` is
  requested through its directory URL. A missing JavaScript file replaced by a
  generic HTML fallback fails even when the host returns HTTP 200.
- Each manifest dynamic route gets a synthetic deep link using
  `__zigapagos_probe__` as its parameter or wildcard value. Its response must
  match the declared shell. A namespace fallback is probed separately when its
  synthetic URL would not match a dynamic route. Missing manifest bundles,
  chunks, and shell files fail planning.
- HTML must receive the site-wide CSP calculated by the same code that emits
  host configuration. Harmless directive/token ordering is accepted; duplicate
  directives, missing headers, and different policies fail. A custom or stricter
  policy needs separate review: this command does not determine whether that
  alternative is correct or secure.
- HTML and stable frontend files must receive `Cache-Control: no-cache`.
  Fingerprint-shaped CSS/JS filenames and manifest-listed split chunks must
  receive `public, max-age=31536000, immutable`, matching the generated policy.
  The filename heuristic has the same [limitations as the emitter](spa.md#cache-control).

Each GET has a 10-second timeout, including reading the body; override it with
`--timeout-ms` (1–120000). Responses cannot consume unbounded body memory:
comparison stops at the first mismatch or at the local file's size. Redirects
fail explicitly and are never followed. Filenames are encoded as URL segments;
symlinks anywhere in the release tree fail with an explanation.

Exit status is **0** for passing probes, **1** for HTTP discrepancies, and **2**
for invalid input or an unsupported release tree. `--json` prints
`{ "ok", "checked", "findings": [{ "code", "path", "message" }] }` for a
completed check; planning/usage errors go to stderr.

## Reproduce a pass and a failure locally

The repository includes a runnable loopback fixture. It prints the exact check
command and keeps serving until interrupted:

```sh
bun tests/deploy/fixture.ts --prefix=/preview
# Run the printed command in another terminal; it should pass.
```

To demonstrate a broken deep-link configuration:

```sh
bun tests/deploy/fixture.ts --prefix=/preview --broken=deep-link
# The printed command exits 1 and names the failed deep-link/fallback URLs.
```

Omit `--prefix` to exercise root hosting. Other fixture failure modes are
`asset-fallback`, `stale`, `cache`, `csp`, `redirect`, `timeout`, and
`body-timeout`. These fixtures test the checker through real HTTP; they do not
emulate or certify nginx, Apache, or ZigBase configuration.

## Coverage limits

The check uses GET requests without authentication. It does not execute browser
JavaScript, test navigation or hydration, inspect images/fonts/maps, fetch
routing manifests or host configuration as public resources, or validate
backend authorization. Without SPA manifests it checks static files and headers
only. It does not prove that linked resources omitted from the release exist;
run `zigapagos doctor` for the separate local-reference audit.

A passing result proves the sampled HTTP paths match this local release and
header policy at that moment. It does not prove cache revalidation/304 behavior,
CDN eviction, a multi-release upgrade, arbitrary application route parameters,
or browser enforcement of CSP. Root/subpath and intentional failure fixtures
are covered here; real-host and paired ZigBase deployment rehearsals remain
separate backlog work. Check only hosts you are authorized to probe.
