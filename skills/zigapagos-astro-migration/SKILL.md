---
name: zigapagos-astro-migration
description: Migrate an Astro site to zigapagos (an SSG with TSX islands and native SPAs) unattended. Use when asked to port, convert, or migrate an Astro project to zigapagos — covers routing, layouts, frontmatter, client:* islands, content collections, and SPA mode, driven by a JSON diagnostics fix loop.
license: MIT
metadata:
  source: https://github.com/valthon/zigapagos
---

# Migrating an Astro site to zigapagos

You are porting an Astro project to zigapagos. The full deterministic mapping
(every Astro concept → its zigapagos counterpart, §1–13) is in
[references/astro-to-zigapagos.md](references/astro-to-zigapagos.md) — read the
sections you need as you reach them; do not guess a mapping that file defines.
Island-porting mechanics (the TSX authoring contract, `host.*` bindings, the
no-npm guardrail) are in [references/recipes.md](references/recipes.md).
Incremental React compatibility is in
[references/react-spa-bridge.md](references/react-spa-bridge.md).

## Preconditions

- The `zigapagos` binary on PATH (or a known path), and `bun` on PATH (islands
  are SSR'd through a Bun sidecar at build time).
- Two command-name traps: building is `zigapagos release` (there is no
  `build` command) and the dev server is `zigapagos dev` (there is no
  `serve` command).

## Procedure

1. **Scan the Astro project.** `zigapagos migrate <astro-dir>` writes a
   `MIGRATION.md` worklist (islands detected per `client:*` directive). Add
   `--scaffold DIR` to also emit one starter `.island.tsx` per detected
   island with the React → `@z/runtime` import swaps pre-applied. Add
   `--doctor PATH --json` to get one JSON object per island:
   `{component, hasDefaultExport, hooks[], hostNeeds[], imports[],
   shared[], guardrailViolations}`.
2. **Create the zigapagos project structure** per
   [references/astro-to-zigapagos.md](references/astro-to-zigapagos.md) §1–2
   (directory layout, `zigapagos.ziggy` config mapping).
3. **Port routing and content** per §3–5 (file-based routes → `content/`
   `.smd` pages; frontmatter mapping is field-by-field in §4).
4. **Port layouts** per §5 (Astro layouts → SuperHTML `.shtml` templates with
   `:extends` chains).
5. **Port islands** per §6–9 and
   [references/recipes.md](references/recipes.md): each `client:*` component
   becomes a `.island.tsx` authored against `@z/runtime` (Preact-compatible
   hooks). Respect the no-npm guardrail — islands import only `@z/runtime`,
   `@z/site-data`, and relative files.
6. **Build and fix.** This is a loop, not a step:

   ```sh
   zigapagos release --format=json -o public
   ```

   Diagnostics are NDJSON on stderr: `{"code","severity","file","line",
   "col","message","help"}`. Match on `code`, never on `message`. Skip any
   stderr line that does not parse as JSON. For the long form of a code:
   `zigapagos explain-code <CODE>` (add `--format=json` for
   `{"code","summary","explanation"}`; stderr, pipe with `2>&1`). Use
   `zigapagos validate --format=json` as the fast pre-check (no island SSR,
   no SPA checks — a subset of release), and
   `zigapagos explain <route>` when a specific route renders wrong.
7. **Audit the built tree.**

   ```sh
   zigapagos doctor public --format=json
   ```

   One NDJSON finding per line on stdout (`{"check","severity","file",
   "message"}`), then a summary object. `abs-url-meta` findings (severity
   `error`) are root-relative og/canonical URLs — fix with
   `$site.host_url`-based absolute URLs. `dangling-internal-link` warnings on
   client-routed SPA paths are expected false positives.
8. **Report.** List what was ported, what was skipped (check the mapping
   spec's "Gaps (not yet supported)" section before calling anything
   unsupported), and any guardrail violations left in `MIGRATION.md`.

## Rules

- Never edit files under the output directory (`public/`) — they are build
  products.
- When a mapping is ambiguous, the mapping spec wins over your prior
  knowledge of either Astro or zigapagos.
- Content collections, `getStaticPaths` dynamic routes, and SPA mode each
  have dedicated sections in the mapping spec — read them before porting
  those features, not after a failed attempt.
