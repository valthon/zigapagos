### Internal

- `contract/test/drift.sh` — the test that proves the cross-tier codegen gate is not vacuous —
  was itself vacuous, and now runs in CI. Its Case B asserted only that `tsc --noEmit` exited
  non-zero, which a compiler that fails to *launch* also does: `contract/` has no
  `node_modules`, so `bun x tsc` resolved `tsc` off `PATH`, hit mise's shim, and died with
  `No version is set for shim: tsc` — exit 1, nothing type-checked, `PASS Case B` printed. Cases
  A and B now assert on the diagnostic text (the `experiments` → `variants` hunk in api-check's
  staged diff; both assignability directions of the `_assert.ts` tripwire, and no diagnostic
  from anywhere else), and a new Case D feeds those assertions canned "the tool never ran"
  output to prove they reject it.

- The same script now runs the repo's *pinned* TypeScript rather than whatever `bun x` resolves.
  `bun x tsc` with no local install can fetch from npm, where `latest` is 7.x — the line this
  repo deliberately caps out — so the gate could have silently type-checked with a compiler the
  manifest pins away from. It now invokes `runtime/node_modules/typescript` through bun and
  fails if the installed version does not match the one locked in `runtime/bun.lock`.

- `drift.sh`'s restore no longer discards more than it mutates. It used to
  `git checkout HEAD -- contract/`, which covers `contract/test/drift.sh` itself — editing the
  script and running it reverted the edit mid-run. The restore set is now exactly the two paths
  a case writes to, a pre-flight refuses to start when either is already dirty, and the EXIT
  trap both restores and fails the run if anything is left behind.

- A `tests/contract/drift.sh` shim puts the gate in CI's `tests/*/*.sh` glob, alongside the
  existing `tests/changelog/assemble.sh` and `tests/release/scripts.sh` hooks. It costs ~1.5s
  and spawns no server, so it runs in the `e2e-rest` shard rather than a job of its own. Being
  outside that glob, and unnamed in `ci.yml`, is why the rot above went unseen.

- `examples/tsx-site/test/spa.sh` had rotted the same way, and is fixed. Its two nginx
  assertions expected the *unquoted* `try_files $uri $uri/ /app/index.html;`, but
  `emit-host-config.ts` has run every interpolated route value through `nginxQuote()` since
  that helper landed, so both greps had matched nothing for as long as they had existed — and
  the script sits outside the `tests/*/*.sh` glob, so nothing ran it. They now match the quoted
  form byte-for-byte, with a third assertion covering the dynamic `location`'s `try_files`
  order. The emitter itself was never at risk: `runtime/scripts/emit-host-config.test.ts` pins
  the same strings and does run in CI. What the e2e assertions add is that those bytes actually
  reach `zig-out/site/app/nginx.nginx.conf` in a real build.

- A new gate, `tests/meta/script-coverage.sh`, makes that class of rot impossible to introduce
  silently: every test script must be either run by CI or listed in `tests/meta/unrun-scripts.txt`
  with a written reason, and the gate fails on one that is neither — as well as on a stale row
  for a script that has since been wired up or deleted. This is the same shape as
  `scripts/allocator-allowlist.txt` and its checker. It is `git ls-files` plus `grep` over
  tracked text, so it costs no toolchain and runs in well under a second.

  The inventory it enforces records the audit behind it: all 34 tracked test scripts were run by
  hand, 20 are covered by CI, and the 14 that are not (`site/test/build.sh` plus the 13 under
  `examples/tsx-site/test/`) all currently pass. Each row carries its measured wall-clock and
  what adopting it would cost, so the trade-off can be re-checked rather than re-derived.
