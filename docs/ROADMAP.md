> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/roadmap/> — the site is the canonical reading experience.

# Zigapagos roadmap

North star: **rich interfaces with simple output.** Build with familiar web
languages, generate production code quickly, and deploy static files. The quality
of the shipped frontend comes first: correct HTML and assets, deliberate browser
JavaScript, and straightforward hosting.

Prioritize output correctness, browser efficiency, production build speed, and
deployment simplicity before adding abstractions. Keep plain CSS and independently
chosen frameworks/design systems viable. Support direct development and coding
agents through the same source, APIs, and local tools; AI is helpful, never required.

ZigBase extends the frontend into a complete application with trusted backend
services. Keep that integration deliberate and independently buildable. Migration
remains a supported entry path, with Astro as its reference; adapter breadth is
secondary to the quality of the resulting application.

Unchecked work below is planned or partial, not a delivery commitment. The
subsystem references describe current behavior: [islands](islands.md),
[SPAs](spa.md), [assets](assets.md), and [cross-tier codegen](cross-tier-codegen.md).
The [application guide](building-apps.md) covers styling, deployment, and pairing.

## Feature backlog and completion evidence

### P1 — Make static output dependable and easy to ship

- [x] **Document-relative output audit.** `doctor` checks local `href`/`src`
  page and asset references, with fixtures for nested pages, query strings,
  URL prefixes, colon filenames, and missing files. Unsupported `<base href>`
  semantics report skipped coverage and fail the audit. Read-only auditing and
  deterministic human/JSON diagnostics are preserved; CSS URLs, `srcset`, and
  browser route execution remain outside this check. See [diagnostics](diagnostics.md).
- [ ] **Deployment verification.** Provide reproducible checks for static hosts,
  including root and subpath hosting, SPA deep links, CSP, and cache behavior
  across a release. Test with and without ZigBase; documented host configuration
  must be sufficient without a production frontend toolchain.
- [x] **Inspect and budget emitted output.** `inspect-output` inventories raw
  HTML/CSS/JS file bytes, lists HTML script/island/modulepreload references, and
  enforces opt-in aggregate byte budgets. Regression fixtures cover one-byte
  overruns and zero-JS pages. [Measurement boundaries](output-inspection.md)
  distinguish all emitted files from actual browser transfers.
- [ ] **Measure route loading cost.** Resolve local references, import maps, and
  module dependencies; distinguish initial and lazy graphs, compressed transfer,
  and external resources without treating unknown sizes as zero.

### P1 — Shorten production builds without weakening checks

- [x] **Batch stylesheet minification.** `release --css-minify` uses the bundled
  driver in one Bun process, preserving independent stylesheet URLs/imports,
  installed paths, and failure behavior. Legacy custom drivers remain supported.
  Byte parity and process-count reduction have release regression coverage;
  [assets](assets.md) records the reproducible, isolated CSS-phase benchmark.
- [ ] **Measure and remove repeated build work.** Publish repeatable content,
  islands, and SPA build fixtures with cold/warm conditions and tool versions.
  Optimize measured bottlenecks; any cache must demonstrate correct invalidation
  for source, config, dependencies, toolchain, and missing outputs. Keep
  correctness and type checks enabled. No timing thresholds that turn CI flaky.

### P1 — Keep authoring close to the web

- [x] **Minimal HTML/CSS starting point.** `init --minimal` offers a minimal scaffold
  alongside the sample site: one semantic page and ordinary stylesheet, with no
  demo blog, imposed visual system, or application JavaScript. Verify the built
  output and retain useful project instructions without requiring an agent.
- [x] **Styling and component compatibility example.** `examples/styling-site`
  verifies plain CSS, externally compiled Tailwind 4.3.3, and a local reusable
  Preact component through release and browser checks. Imports, font/image
  loading, and static routes without scripts are tested. This establishes these
  integration patterns, not arbitrary React libraries or CSS-in-JS extraction.

### P2 — Build complete applications on that foundation

- [ ] **Supported application starter.** Add an explicit application path alongside
  the current content scaffold. Include SPA navigation, accessible form patterns,
  loading/empty/error states, and browser journeys. Keep a frontend-only variant
  usable with an existing API; document every required backend contract. Complete
  when a fresh checkout builds, runs, and verifies without undocumented steps.
- [ ] **ZigBase paired workflow.** Build on the existing pairing guide and reference
  application. Coordinate scaffolding, pinned versions, schema provisioning,
  authoritative client generation, custom backend selection, dev lifecycle, and
  verification through documented project commands. Prove sign-in/out, expiry,
  user-owned CRUD, denied cross-user access, and a custom trusted operation with
  backend and browser tests. Keep each project independently buildable.
- [ ] **Everyday frontend patterns.** Select and document supported patterns or
  libraries for forms and validation, accessible dialogs, data loading and
  mutations, pagination, uploads, and realtime state. Cover failed requests,
  reconnects, stale responses, and session changes. Prefer composition over new
  abstractions where it suffices. Complete with runnable examples, keyboard and
  browser checks, and explicit compatibility boundaries.

### P2 — Make iteration dependable for developers and agents

- [ ] **Reliable edit/build/browser loop.** Extend existing structured diagnostics,
  background status, and reload tooling. Reproduce and resolve intermittent dev
  rebuild failures; verify successive edits, failed builds followed by recovery,
  and process teardown. Put focused browser regressions on the PR path when the
  relevant runtime changes; keep broader scheduled coverage explicit.
- [ ] **Application-evolution evaluation.** Pin a paired reference app and a
  frontend-only app. Build and change them through both a documented direct
  workflow and recorded agent runs. Include populated-data schema changes, team
  permissions, a custom operation, and dependency upgrades. Independently verify
  existing journeys, authorization, generated clients, and restart behavior.
  Record revisions, model, elapsed time, interventions, and available cost data;
  a creation demo does not qualify later application evolution.
- [ ] **Actionable application diagnostics.** Use those evaluations to identify
  recurring setup, type, hydration, and backend-contract failures. Improve
  discoverability and error context through ordinary CLI output and structured
  equivalents. Complete when the documented fix works without private context.

### P2 — Prove efficient delivery and a practical growth path

- [ ] **Frontend performance evidence.** Measure initial JS, transferred assets,
  render and interaction behavior, and navigation on representative content and
  application routes. Record device/network profiles, dataset, revisions, and
  reproducible procedures. Cover low-end clients and large result sets; avoid
  equating native build speed with browser or backend performance.
- [ ] **Paired deployment and operating rehearsal.** Coordinate with ZigBase's
  capacity and growth backlog. Exercise a versioned frontend/backend release,
  contract changes, rollback, backup/restore, and the frontend behavior during
  backend errors or reconnects. Record team actions and recovery time. Use
  measured workloads for scaling claims; database/replica coordination belongs
  to ZigBase, with browser journeys verifying the complete application.
- [ ] **Compatibility and upgrade guidance.** Publish tested runtime, package,
  browser, and ZigBase combinations, with upgrade notes and an exercised consumer
  upgrade. Verify frontend-only hosting as well as the paired deployment.

### Continuing work

- [ ] **ZigBase-native codegen adoption.** The mechanism exists; retire duplicate
  hand-authored contracts in real consumers using the backend's authoritative
  generation path. Verify drift against the paired version, including fresh data
  provisioning. Preserve explicit warnings when backend evidence is unavailable.
- [ ] **Migration maintenance.** Keep existing adapters and parity boundaries
  reliable. Prioritize gaps demonstrated by real application migrations over
  adding new framework names. Unsupported behavior must remain visible.
- [ ] **Dev log rotation.** Bound logs for long-running background sessions.
- [ ] **Windows builds.** Gated on the Zig 0.17 port described above.

## Evidence and positioning maintenance

- Lead README, homepage, onboarding, and canonical docs with the shipped frontend:
  clean static output, fast production builds, familiar languages, and styling
  freedom. Explain agent support and ZigBase pairing as ways to extend that value.
- Publish reference-app and agent results with exact revisions and coverage;
  refresh them for release candidates. Separate shipped features, measurements,
  and objectives. No universal scale or comparative cost claims without evidence.
- Keep ZigBase as the authority for server policy, persistence, jobs, and resource
  management. Zigapagos owns frontend behavior and the quality of its integration.

## Implemented building blocks

Browser error relay ([observability](observability.md)), same-origin fetch defaults,
live feature flags, and state-preserving reload are available in the runtime.
Applications still need to wire their backend endpoints and flag streams.
Router navigation honors reduced motion and conditional outlets are diagnosed on
layout exit rather than before they have a chance to mount.

Background dev-server management includes `stop|status|logs|wait`, build-aware
`/_zigapagos/status`, AI-agent auto-detection, and NDJSON build logs; see
[dev-server.md](dev-server.md). Log rotation remains follow-up work.

**ZigBase integration seams.** Route guards, browser error relay, same-origin
fetch defaults, live flags, and native codegen each have a backend half, tracked
in the ZigBase repository. The zigapagos-side items proceed against the backend
capabilities that already exist: the `__features` signal, the SSE endpoint
(`GET /api/realtime/sse`), and `gen-client` typed output.

---

## Fork policy

Zigapagos is a **permanent fork** of the upstream SSG (see [README
Acknowledgements](../README.md#acknowledgements); git remote name `upstream`).
Policy:

- **Sync at upstream release tags only** — never track upstream main/nightly.
  Each sync is a deliberate merge with its own branch, test pass, and review.
- **The Zig 0.17 port is deferred until Zig 0.17.0 is released.** Upstream moved
  to 0.17.0-dev; we stay on released Zig 0.16.0. When 0.17.0 ships, the port and
  the next upstream tag sync land together.
- **Keep the seam narrow:** new features go in new files with guarded hooks.
  The upstream-touched surface is ~18 files; avoid growing it without need.

---

## Platform support

- **Windows is unsupported until the Zig 0.17 port.** Inherited upstream code
  (`src/cli/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile on
  stable Zig 0.16.0 (`std.os.windows` does not expose `OVERLAPPED` /
  `PAGE_READONLY`); the fix rides the upstream 0.17-dev branch. CI runs ubuntu +
  macOS; `windows-latest` returns with the port.
- **arm64 is supported** on Linux and macOS with native release archives, npm
  platform packages, and the shell installer.
- **FreeBSD is not currently a supported build target.** There is no checked-in
  Wuffs translation shim for it, no release archive, and `dev` still selects
  the inotify-based Linux watcher instead of a native kqueue backend. FreeBSD
  15 added inotify, but that does not close the Wuffs or target-selection gaps.

---

## Delivery rule

Each item lands the established way: one feature per branch → unit test + real-
browser e2e → code review → fast-forward merge to main.
