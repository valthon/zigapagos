### Internal

- Eleven of the fourteen test scripts `tests/meta/unrun-scripts.txt` inventoried as knowingly
  unrun now run in CI: the non-browser `examples/tsx-site/test/*.sh` — island SSR and the
  bundle/import-map wiring, SSR↔CSR parity, byte-parity against a raw `bun build`, depfile
  incrementality, the props-check gate in both directions, `migrate --doctor`, and the four SPA
  prerender scripts (routing manifest, nginx/zigbase host config, code splitting, baked flag
  defaults, guarded routes, nested layouts) — plus the live-server smoke test.

  They are a step in the existing `e2e-dev-loop` job rather than a `tests/<area>/` shim, and the
  distinction is the whole point. Every one of them runs `zig build` inside `examples/tsx-site`,
  i.e. a full consumer build of zigapagos-as-a-dependency, and `e2e-dev-loop` is the only job
  that already pays for one — its `tests/serve/dev.sh` step drives that project's own
  `zig build dev`. A shim would have put them in `e2e-rest`, which builds the repo and not the
  example, buying a cold ~265s consumer build and making that job the run's critical path.
  Measured against the warm tree the job already has, the eleven cost **49s** in CI (29s
  locally) against the 468s the `dev.sh` step above them takes. `serve.sh` alone was
  inventoried at 76.1s; behind `dev.sh` it is ~5s, which is the placement argument in one
  number.

  The list is literal, not a glob, for the opposite reason `e2e-rest` uses a glob: a new sibling
  in that directory should NOT be adopted onto the PR path automatically — it might be the next
  one that needs a browser or four minutes. Being unnamed there is exactly what makes
  `script-coverage.sh` stop and ask.

- `tests/meta/script-coverage.sh` no longer counts a script as CI-run because a workflow
  *comment* names it. Its rule (b) was a plain `git grep` over `.github/workflows/`, so prose
  saying "these two are deliberately not run here" would have vouched for precisely the scripts
  it was disclaiming — and, since both are also inventoried, would have failed the gate with
  "run by CI but also listed". Rule (b) now applies the same non-comment filter rule (c) already
  had. The two Playwright paths are spelled in full in that comment on purpose: they pin the
  filter, because removing it turns the gate red by name.

- The three scripts still inventoried carry a recommendation rather than only a cost.
  `site/test/build.sh` is not free in any `ci.yml` job (`site/` is a third consumer project with
  its own cache: 120.3s cold, and `e2e-dev-loop`'s warm `examples/tsx-site` tree buys it
  nothing), but it is nearly free in `pages.yml`, which already runs `bun install && zig build`
  in `site/` before uploading — the five assertions are greps over that finished tree, ~2s. The
  two Playwright scripts want a nightly `schedule:` plus `workflow_dispatch:` workflow with a
  `playwright install --with-deps chromium` step, not the PR path: what they catch arrives with
  a `runtime/src` change, and a browser job on every PR is the kind of cost that gets switched
  off later.
