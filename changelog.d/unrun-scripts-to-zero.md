### Internal

- `tests/meta/unrun-scripts.txt` is **empty**. All 36 tracked test scripts are now run by CI;
  the inventory that started at 14 rows and was cut to 3 is at 0. The file stays because the
  gate reading it is the point, not the list.

  `site/test/build.sh` moved into `pages.yml`, between `Build site` and `Upload artifact`. That
  makes it a **deploy gate**: a failed assertion fails the build job, the artifact is never
  uploaded, and `deploy` (which `needs: build`) never runs, so the previous good deployment
  stays live. It is nearly free there — the workflow has already built `site/`, so the script's
  own install and build are warm no-ops and the five greps measured 1.7s — against ~120s in any
  `ci.yml` job, because `site/` is a third consumer project with its own `.zig-cache` that
  nothing else warms. The residual gap is stated rather than glossed: `pages.yml` triggers on
  push to `main` and manual dispatch only, so these assertions gate the deploy and not the PR.

  `examples/tsx-site/test/{hydrate,spa_slice}.sh` moved into a new `browser-e2e.yml` on a
  nightly `schedule:` plus `workflow_dispatch:`. Scheduled rather than PR-gating because each is
  ~125s on top of a ~265s cold consumer build plus a ~150MB browser install, and because what
  they catch — a real-browser hydration or runtime-slicing regression — arrives with a
  `runtime/src` change or a dependency bump, unattended. Each script gets its own matrix runner
  (`fail-fast: false`): `spa_slice.sh` opens by `rm -rf`ing `.zig-cache` and `zig-out`, so the
  two cannot share a build, and separate runners make that hazard structurally impossible rather
  than merely avoided.

  One correction to the plan the inventory carried: the install step is
  `playwright install --with-deps chrome`, **not** `chromium`. All ten `*_playwright.py` helpers
  launch with `channel="chrome"`, which on Linux resolves to `/opt/google/chrome/chrome` — the
  bundled Chromium build satisfies none of them, and the run would have died at browser launch
  after paying for the whole consumer build.

- `tests/meta/script-coverage.sh` gained a self-test, `tests/meta/script-coverage.test.sh`,
  in the shape of `scripts/check-allocator-contracts.test.sh`: seven cases against throwaway git
  repos in `$TMPDIR`. That gate has shipped three defects already — a self-vouching inventory, a
  `pipefail` + `grep -q` SIGPIPE race, and a comment filter applied to one rule but not the
  other — and every one made it pass when it should have failed.

  Two of the cases exist because emptying the inventory silently removed the only thing pinning
  the comment filter. That filter is what stops a script a workflow merely *mentions* in prose
  from counting as run, and it was pinned by accident: while the two Playwright scripts were
  inventoried, dropping the filter made the gate see them as both CI-run and listed and fail by
  name. With the inventory empty, removing the filter now breaks nothing in the tree —
  confirmed by deleting the filter line and watching the real gate still pass 36/36. Case 5
  makes the pin deliberate; case 6 is its guard rail, that comment-awareness has not become
  "never believe a workflow".
