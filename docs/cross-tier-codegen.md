> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/cross-tier-codegen/> — the site is the canonical reading experience.

# Cross-tier type codegen (ZigBase → TS)

Zigapagos generates typed TypeScript API clients so islands and the SPA can't
drift from the ZigBase backend.  A drift gate catches mismatches before they
reach production.

There are two codegen **modes**, selected by `contract/codegen.config.json`:

| Mode | Source of truth | Typed client | Drift gate |
|------|-----------------|--------------|------------|
| `openapi` (default) | a hand-authored `contract/zigbase.openapi.json` | emitted by `apigen.ts` into `contract/generated/` | regen + `git diff` |
| `zigbase` | the **backend's own** `zig build gen-client` output | that output, vendored into the app tree | regen from backend + diff |

`openapi` is the bootstrap mode for a backend with no schema emitter; the bulk
of this document (contract authoring, `apigen.ts`, the `_assert.ts` tripwire)
describes it.  When the config is **absent** the mode is `openapi`, so nothing
below changes for an existing consumer.  A ZigBase backend already emits a
fully-typed client from its comptime config, so `zigbase` mode adopts that
directly and retires the parallel OpenAPI doc — see
[ZigBase-native mode](#zigbase-native-mode-mode-zigbase) below.

---

## Contract authoring

**File:** `contract/zigbase.openapi.json`

The contract is an OpenAPI 3.0.3 document.  The emitter (`apigen.ts`) supports
a strict subset; anything outside that subset throws loudly at codegen time.

### Supported OpenAPI / JSON Schema subset

| Construct | TS output |
|-----------|-----------|
| `type: "string"` | `string` |
| `type: "number"` / `"integer"` | `number` |
| `type: "boolean"` | `boolean` |
| `type: "array", items: S` | `T[]` |
| `type: "object", additionalProperties: S` (no declared properties) | `Record<string, T>` |
| `type: "object", properties: {...}` (with or without `additionalProperties`) | `export interface Name { ... }` |
| `type: "string", enum: [...]` | `"a" \| "b" \| ...` (string-literal union) |
| `$ref: "#/components/schemas/Name"` | `Name` (the referenced interface) |

### Unsupported constructs (loud-fail)

- `oneOf` / `allOf` / `anyOf` — throws at codegen time.
- `$ref` to a target other than `#/components/schemas/<Name>` — throws.
- Nested inline objects (a schema with `type: "object"` + `properties` inside
  another schema's property) — use a top-level `$ref` for nested objects.
- Unknown or missing `type` on a non-`$ref`, non-enum schema — throws.

### Contract version

Add `"x-zigbase-contract-version": "<date>.<rev>"` at the document root.
This is emitted as `export const CONTRACT_VERSION = "..."` in `types.ts`.

---

## The code generator

**Script:** `runtime/scripts/apigen.ts`

```
bun runtime/scripts/apigen.ts \
  --schema <openapi.json> \
  --out <output-dir> \
  [--validators=post|all|none]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--schema <f>` | (required) | Path to the OpenAPI JSON file |
| `--out <dir>` | (required) | Directory to write generated files into |
| `--validators=post` | `post` | Emit loud-fail `assertX()` shape-checkers for POST response schemas and call them before returning |
| `--validators=all` | — | Same as `post` in v1 (GET validators are out of scope) |
| `--validators=none` | — | No runtime shape-checkers; POST wrappers cast and return directly |

### Generated files

| File | Contents |
|------|----------|
| `types.ts` | `export interface`/`export type` for every component schema + `CONTRACT_VERSION` const |
| `client.ts` | Typed wrappers that call `@z/runtime/host`; one function per endpoint |
| `_assert.ts` | Compile-time structural-identity check between generated `ResolvedState` and the runtime type |

The client imports only `@z/runtime/host` and `./types.ts` — never bare
`@z/runtime` or Preact.

---

## Build integration

### `zig build apigen` — regenerate

Runs apigen from the project root, writing into `contract/generated/`.  Use
this after editing `contract/zigbase.openapi.json`.

```
mise exec -- zig build apigen
```

### `zig build api-check` — drift gate

Reruns apigen, stages the output with `git add contract/generated`, then runs
`git diff --cached --exit-code contract/generated`.  Exits non-zero if the
committed generated directory differs from a fresh regen.  Mirrors the
`setupSnapshotTesting` pattern used elsewhere in the build.

```
mise exec -- zig build api-check
```

Add `zig build api-check` to CI alongside the snapshot tests.

---

## The `_assert.ts` compile tripwire

`contract/generated/_assert.ts` contains:

```typescript
import type { ResolvedState as Gen } from "./types.ts";
import type { ResolvedState as Runtime } from "../../runtime/src/flags.ts";

const _a: Gen     = {} as Runtime;
const _b: Runtime = {} as Gen;
void _a; void _b;
```

These two assignments enforce **structural bi-directional assignability**.  If
ZigBase changes the `ResolvedState` envelope (e.g. renames `experiments` to
`variants`) and apigen regenerates `types.ts`, then `Gen` gains `variants` but
`Runtime` still has `experiments`.  Either `_a` or `_b` (or both) becomes a
type error and `tsc --noEmit` fails.

**How to run the tripwire:**

```
cd contract && mise exec -- bun x tsc --noEmit -p tsconfig.json
```

`contract/tsconfig.json` includes only `generated/types.ts` and
`generated/_assert.ts` so the check is fast and isolated.

> **Note:** `client.ts` imports `@z/runtime/host` which is a host-side import.
> Its type-correctness is verified in the consumer project's own `tsc` pass, not
> by this in-repo tripwire (which covers `types.ts` + `_assert.ts` only).

---

## Drift-catch proof

`contract/test/drift.sh` proves the gate is not vacuous.  It runs three cases:

1. **Schema drift** — mutates `contract/zigbase.openapi.json` without
   regenerating, then asserts `zig build api-check` exits non-zero.
2. **Type divergence** — mutates the schema, regenerates, then asserts
   `tsc --noEmit` exits non-zero (generated `ResolvedState` ⊄ runtime
   `ResolvedState`).
3. **Clean state** — after reverting all mutations, asserts both gates pass.

The script uses a `trap` on EXIT to restore the tree even on early failure.

---

## ZigBase-native mode (`mode: "zigbase"`)

In `zigbase` mode there is **no hand-authored OpenAPI doc and no `apigen.ts`
emission**.  The typed client is the backend's own `zig build gen-client`
output — a single `zbase.gen.ts` (header `// generated by zigbase — do not
edit` + `// schema-hash: <hash>`, importing `@zigbase/client` and its
`/typed` / `/realtime` subpaths, exporting typed record interfaces +
services) — **vendored** into the app tree as a committed artifact, exactly
like `openapi` mode's `contract/generated/`.  So the repo still builds and
type-checks without the backend checked out.

### Config — `contract/codegen.config.json`

```json
{
  "mode": "zigbase",
  "zigbase": {
    "genClientCmd": ["zig", "build", "gen-client"],
    "genClientCwd": "../backend",
    "out": "contract/generated/zbase.gen.ts",
    "apiPrefix": "/api",
    "producedPath": "clients/typescript/zbase.gen.ts"
  }
}
```

| Field | Meaning |
|-------|---------|
| `mode` | `"openapi"` (default when the file is absent) or `"zigbase"` |
| `zigbase.genClientCmd` | argv of the backend's gen-client command |
| `zigbase.genClientCwd` | where to run it (cwd-relative or absolute) |
| `zigbase.out` | vendored client destination in the app tree |
| `zigbase.apiPrefix` | API prefix passed to / documented for the generator |
| `zigbase.producedPath` | **optional** — where the command writes its output, relative to `genClientCwd`.  When set, `api-gen` copies `producedPath → out`.  When omitted, the command is expected to write `out` directly. |

`producedPath` exists because a backend's `gen-client` step usually hardcodes
its own output path (e.g. golfsim writes `clients/typescript/zbase.gen.ts`
inside the backend tree).  We run it there and then vendor the result into the
app's `out`.  A backend that accepts an app-tree `--out` can omit `producedPath`.

All paths resolve against the process cwd (the repo root when `build.zig`
invokes the dispatcher); absolute paths pass through.

### The dispatcher — `runtime/scripts/apiclient.ts`

```
bun runtime/scripts/apiclient.ts <gen|check> [--config <path>]
```

- **`gen`** (`zig build api-gen`) — runs `genClientCmd` in `genClientCwd`, then
  vendors `producedPath → out`.  Requires the backend present (you can't refresh
  from an absent backend — that's a hard error, not the check-time fallback).
- **`check`** (`zig build api-check`) — the drift gate.  Re-runs `genClientCmd`
  and diffs the fresh output against the committed `out`.  A backend
  comptime-config change flips the `schema-hash` and produces a different
  client, so `check` **exits non-zero** and renders the diff.  The check is
  non-destructive: when the command writes `out` directly, the committed bytes
  are saved and restored around the regeneration.

### Build integration

`build.zig` reads `mode` from `contract/codegen.config.json` **at configure
time** and wires the matching `api-gen` / `api-check` steps.  When the config is
absent or `openapi`, the exact `openapi` steps from earlier in this document are
wired, byte-identical — `zigbase` mode is a separate branch, so the existing
`openapi` path is never perturbed.  In `zigbase` mode both steps delegate to
`apiclient.ts`.

```
mise exec -- zig build api-gen     # refresh the vendored client from the backend
mise exec -- zig build api-check   # fail if the vendored client drifts
```

### Trust model

- **The config paths are trusted.**  `genClientCwd`, `producedPath`, and `out`
  are developer-authored and committed (`contract/codegen.config.json` in the
  app repo) — not attacker-controlled input.  The dispatcher spawns
  `genClientCmd` via argv (no shell), but it does run a configured command, so
  treat the config like any other build script.
- **The gen-client command must be authoritative and deterministic.**  The drift
  gate compares the command's *fresh* output against the committed client, so it
  is only as strong as the command actually regenerating.  A cached / no-op /
  skipped gen-client that leaves a **stale** `producedPath` on disk would let the
  gate false-pass.  Point `genClientCmd` at a build step that always regenerates
  from the backend's current source (ZigBase's `gen-client` re-emits every run).

### Backend-absent fallback (cross-repo)

`zigbase` mode's full drift gate needs the backend reachable at `genClientCwd`.
Across independently-released repos the backend often isn't checked out (CI on
the frontend repo, a fresh clone, …).  When `genClientCwd` is missing, `check`
does **not** silently pass — it falls back to a weaker but **loud** presence/pin
gate:

- committed `out` **missing or empty** → hard **FAIL** (the vendored client must
  be committed so the repo builds without the backend);
- committed `out` present + non-empty → **PASS** with a `WARNING` log that names
  the absent backend path, records the committed `schema-hash`, and states that
  drift was *not* verified.

So a missing backend degrades coverage visibly, never invisibly.

### Import allowlist (composition with the island import config)

The vendored client imports `@zigbase/client` (+ `/typed`, `/realtime`).  That
is **data/fetch logic — no Preact** — so it does not go through the island
one-Preact bundler.  The consumer allowlists the scope via the
[island import config](./islands.md) `z-runtime.config.json`:

```json
{ "islandImports": { "firstParty": ["@zigbase/client"] } }
```

(`npmCompat` is for react-aliased packages; `@zigbase/client` is first-party
data code, so `firstParty` is the right list.)

### Payoff

For a converted consumer this **deletes** the hand-maintained OpenAPI doc
(`contract/zigbase.openapi.json`) and the emitted `contract/generated/{types,
client,_assert}.ts` (~1,000 lines) — the backend's own typed client is the
single source of truth, and a backend route/field change fails `api-check`
instead of silently lagging a parallel hand-written contract.

### Proven against ZigBase golfsim

The gate is validated against ZigBase's public `examples/golfsim` (it ships a
real `zig build gen-client` + committed `zbase.gen.ts`):

1. `api-gen` vendors golfsim's 903-line `zbase.gen.ts` (schema-hash
   `a69ad908…`) into a scratch app tree; `api-check` → **PASS**.
2. Renaming a golfsim collection field (`rating → stars`) flips the schema-hash
   (`a69ad908… → a8f0f702…`); `api-check` re-runs the backend, sees the fresh
   client differ from the committed one, renders the `rating: number →
   stars: number` diff, and **exits non-zero**.
3. With the backend path pointed at a non-existent dir, `api-check` logs the
   `WARNING` presence gate and passes on a present committed client, and hard-
   fails when it's missing.

---

## Production output home

For the pilot-site migration, the generated client lives at:

```
@your-org/shared-lite/api
```

This path is already on the allowlist in
`runtime/scripts/lint-island-imports.ts` so islands may import it without
triggering the no-npm guardrail.  The in-repo proof (`contract/generated/`)
is a development artifact only.

---

## v1 scope and gates

**v1 hand-authors `contract/zigbase.openapi.json` in zigapagos (bootstrap
artifact).**  The source-of-truth flips to a ZigBase `api-schema` emitter
in a separate repo — that emitter is the external gating dependency (design
Task 7); until it lands, bumping the contract is a reviewed zigapagos PR.

**Porting the marketing flags/contact islands and the `useCustomer` store to
the generated client is deferred to the pilot-site migration (design Task 5).**

v1 toolchain summary:

| Component | Status |
|-----------|--------|
| `contract/zigbase.openapi.json` — bootstrap artifact | ✅ committed |
| `runtime/scripts/apigen.ts` — emitter | ✅ committed |
| `contract/generated/{types,client,_assert}.ts` — output | ✅ committed |
| `contract/tsconfig.json` — compile tripwire config | ✅ committed |
| `zig build apigen` / `zig build api-check` — drift gate | ✅ wired |
| POST response validators (`assertX`) | ✅ emitted |
| `contract/test/drift.sh` — gate proof | ✅ committed |
| ZigBase `api-schema` emitter (separate repo) | ✅ shipped (ZigBase `gen-client`) |
| `zigbase` mode — config + `apiclient.ts` + `build.zig` branch | ✅ committed |
| `zigbase`-mode drift gate proven vs ZigBase golfsim | ✅ validated |
| Consumer port: marketing islands → generated client | ⏳ consumer migration |
