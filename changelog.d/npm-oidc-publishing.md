### Internal

- npm publishing authenticates with **OIDC trusted publishing** instead of a stored
  registry credential. Each package names `valthon/zigapagos` + `release.yml` as its
  trusted publisher on npmjs.com, and the `publish-npm` job exchanges the OIDC identity
  GitHub mints for the run for a short-lived registry token — so the right to publish
  belongs to that one workflow rather than to a credential anything able to read it
  could use. The job's guard that *failed* when `NPM_PUBLISH_ENABLED` was set but no
  stored credential was configured went with it; against a repository that deliberately
  has none, that guard would have failed the next tag. The `NPM_PUBLISH_ENABLED` arming
  switch is unchanged.
- The publish job installs and asserts `npm >= 11.5` before uploading anything. OIDC
  trusted publishing is an npm 11.5 feature and `node-version: 24` does not imply it —
  node 24.2.0 bundles npm 11.3.0, and 24.5.0 was the first with 11.5.1 — so an older
  npm would have failed as a bare authentication error partway through a
  dependency-ordered publish.
- `tests/meta/npm-oidc.sh` pins the publishing job's shape: `publish-npm` must keep
  `id-token: write` — without it GitHub mints no identity and OIDC has nothing to
  exchange — and both gating conditions. The job runs only on a `v*` tag, so without a
  gate these are properties nothing tests until a release.
- The published-release smoke workflow now also installs `zigapagos@<version>` from npm
  on each platform and runs it. The archives it already checked cannot show a platform
  package that was never published, or an `optionalDependencies` resolution that yields
  an install with no binary in it.
