> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/roadmap/> — the site is the canonical reading experience.

# Zigapagos roadmap

North star: **excellent DX + LLM-native unattended migration from Astro.** Astro
remains the reference architecture and the lead marketing story. Migration
adapters for Next.js, Gatsby, Nuxt/Vue, Hugo, Jekyll, Eleventy, and Hexo extend
that capability without turning Zigapagos into a framework-conversion brand. Every item below is
judged against "does this help an LLM migrate a real site cleanly, and does the
result run correctly with good DX."

This page is what is *planned* and what is *deferred*. For what the code does
today, read the subsystem specs — [islands](islands.md), [native
SPAs](spa.md), [assets](assets.md), [cross-tier codegen](cross-tier-codegen.md)
— and for what changed in the current release, [the changelog](../CHANGELOG.md).

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

## Planned work

- **ZigBase-native codegen adoption.** Consume the backend's own `gen-client`
  output instead of a hand-authored OpenAPI document. The mechanism ships (see
  [cross-tier codegen](cross-tier-codegen.md)); what remains is retiring the
  bootstrap OpenAPI path in real consumer projects.
- **Router and DX paper cuts** — browser error relay, same-origin fetch
  defaults, live feature flags, state-preserving reload. **Background
  dev-server management shipped** (`zigapagos dev --background` +
  `stop|status|logs`, build-aware `/_zigapagos/status`, AI-agent
  auto-detection; issue #126, see [dev-server.md](dev-server.md)); its own
  v1.1 remainder — `dev wait`, NDJSON structured logs — stays on this list.
- **Windows builds**, gated on the Zig 0.17 port above.

**ZigBase integration seams.** Route guards, browser error relay, same-origin
fetch defaults, live flags, and native codegen each have a backend half, tracked
in the ZigBase repository. The zigapagos-side items proceed against the backend
capabilities that already exist: the `__features` signal, the SSE endpoint
(`GET /api/realtime/sse`), and `gen-client` typed output.

---

## Delivery rule

Each item lands the established way: one feature per branch → unit test + real-
browser e2e → code review → fast-forward merge to main.
