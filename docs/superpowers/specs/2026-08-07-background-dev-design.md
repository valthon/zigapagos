# Background dev server management — design

**Issue:** [#126](https://github.com/valthon/zigapagos/issues/126) · **Date:** 2026-08-07 ·
**Status:** approved design, pre-implementation

> **Amended post-implementation** (final whole-branch review, 2026-08-08): six
> points below drifted from what shipped, where the implementation and
> `docs/dev-server.md` agree with each other and this design doc was simply
> not updated — `dev stop`'s escalation targets the dev **pid**, not its
> process group; the lifetime flock is held on a separate create-once
> `dev.lock`, not on `dev.json` itself; `--ignore-lock`'s notice is
> unconditional, not a read-only lockfile check; `REPL_ID` is deliberately
> excluded from agent detection, not included; `dev status` prints
> `started_at`, not a computed uptime; and a corrupt (unparseable) `dev.json`
> is treated as absent but only actively removed on the stale-but-parseable
> path. Each is called out in place below; none reflect a design change.

## Why

Astro 7.0–7.2 shipped background dev server management (`astro dev --background`, a lockfile,
`dev stop|status|logs`, a `/_astro/status` health endpoint, AI-agent auto-detection) aimed
squarely at AI coding agents — zigapagos's stated north-star audience. An agent driving
`zigapagos dev` today must background and babysit the process itself, and a `kill -9` of dev
orphans zigbase on the port (a gap `src/cli/dev.zig` documents, with `pkill zigbase` as the
official recovery).

This design matches Astro's feature and beats it in four ways Astro cannot easily follow:
build-aware status, flock-based liveness, whole-process-tree recovery, and (v1.1) a blocking
`dev wait` verb.

## Research findings that shaped the design

Astro's implementation (read from `withastro/astro` source, PR #16610 and follow-ups):

- Parent spawns one detached child with stdio redirected to `.astro/dev.log`, polls for the
  lockfile as the readiness handshake, prints URL + PID, exits. No supervisor.
- Lockfile `.astro/dev.json`: `{pid, port, url, urls?, background, startedAt}`. Plain
  check-then-write — not atomic, no lock held.
- Liveness is `kill(pid, 0)`: PID reuse fakes liveness; `EPERM` (alive, not yours) is
  misread as dead.
- The health endpoint is literally `{"ok": true}` — nothing an agent can act on.
- The opt-out env var (`ASTRO_DEV_BACKGROUND=0`) doubles as the child recursion guard, so
  opting out corrupts the lockfile's `background` field (`!!"0"` is truthy).
- Two post-release fixes we adopt on day one: hybrid environments (Warp) excluded from agent
  detection (7.0.1), and `--ignore-lock` for deliberate parallel instances (7.1), which
  hard-errors when combined with `--background` or `--force`.
- Agent detection delegates to `am-i-vibing` (env-var table: `CLAUDECODE`,
  `CURSOR_TRACE_ID` + pager heuristic, `GEMINI_CLI`, etc.); only `type === 'agent'`
  environments auto-background, never `hybrid`.

Comparable daemons (turbo, watchman, Nx, Bazel): stale pidfiles after crashes are common
enough that turbo ships `turbo daemon clean` as a first-class escape hatch; watchman's fix
history shows lock-before-fork is the only reliable anti-duplicate ordering; the robust
liveness primitive is a kernel-held file lock, which dies with the process.

Codebase facts that gate the design (see `src/cli/dev.zig`, `src/cli/reload.zig`,
`src/cli/e2e.zig`):

- `dev()` is `noreturn`; all threads are detached and never joined; SIGTERM into the
  existing `reaper` is the only exit path, and that is already correct.
- Ports are late-bound (serve port at zigbase spawn, reload port earlier but also dynamic),
  so the lockfile can only be written after `waitReady`.
- `.zigbase/` is the established per-project state dir: created early, guaranteed outside
  every watched dir, never deleted by dev.
- The reload server is an `std.http.Server` that never inspects request paths and already
  sends `access-control-allow-origin: *`.
- Zig 0.16 `std.process.SpawnOptions` has no detach flag and no post-fork hook, but has
  `pgid` and file stdio; `std.c.flock` and `std.c.setsid` exist. Re-exec-self is already an
  established pattern (`defaultRebuildArgv`).
- `zig build check -Dsingle-threaded` compiles everything; `dev()` fatals early under
  single-threaded, so control verbs must dispatch before that gate.
- zigbase (pinned v0.12.0) already serves `GET /api/health` →
  `{"status":"ok","backend":"sqlite","versions":{...}}`. It has no daemon machinery, by
  design — production zigbase is supervised by Docker/systemd.

## Decisions (settled in brainstorming, 2026-08-07)

1. **Implement in zigapagos, not zigbase-first.** The unit being daemonized is the dev loop
   (watcher + debouncer + rebuild + SSE + zigbase child); zigbase must remain a tracked
   foreground child of dev's process group for the reaper cascade. All differentiators are
   dev-side. Self-daemonization would be an anti-feature for production zigbase. The spec's
   conventions (below) are written to be liftable into a future `zigbase serve --background`
   if a standalone need appears.
2. **Build-aware status ships in v1.** The rebuild loop already owns every field.
3. **The reload server becomes an always-on control server.** `--no-live-reload` disables
   reload injection and reload events only, not the server — background mode without a
   health endpoint is half a feature.
4. **Agent detection auto-backgrounds, like Astro** (agent-type environments only), with an
   explicit env-var opt-out. No auto-JSON coupling.
5. **v1.1, not v1:** `dev wait` and NDJSON structured logs.

## Design

### CLI surface

```
zigapagos dev [--background] [--force] [--ignore-lock] [existing flags…]
zigapagos dev stop
zigapagos dev status [--json]
zigapagos dev logs [--follow]
```

- Sub-verbs are the repo's first two-level subcommand. `dev()` already receives
  `args[2..]`, so a leading non-flag token dispatches to `src/cli/dev_control.zig`
  **before** the single-threaded gate — the control verbs need no threads and stay
  reachable (and compiled) under `-Dsingle-threaded`. Unknown sub-verbs keep today's
  "unexpected argument" fatal.
- `--background` is idempotent: a live lock means "already running at <url> (pid N)",
  exit 0. `--force` stops the existing instance first (same path as `dev stop`), then
  starts. `--ignore-lock` never writes the lockfile and always prints an unconditional
  generic untracked notice — **amended:** it does not read the lockfile or name a
  coexisting instance's URL, whether or not one exists — and hard-errors when combined
  with `--background` or `--force`.
- `dev status --json` emits one JSON object on stdout. This is a new, self-contained
  contract — it does not ride the `--format` gate in `src/main.zig` (which is
  release-only, with a comment explaining why an ungated pre-scan is wrong).
- Help text: the "Dev loop" section of `src/fatal.zig`'s menu gains the new flags and
  verbs; the menu-sync test keeps it honest.

### Daemonization (POSIX; Windows is a comptime no-op until the 0.17 port)

No supervisor process. `dev --background`:

1. Parent resolves its own binary (`std.process.executablePathAlloc`, the
   `defaultRebuildArgv` pattern) and re-execs `dev` with the original flags minus
   `--background`, plus:
   - `ZIGAPAGOS_DEV_BACKGROUND_CHILD=1` in the environment — the **internal recursion
     guard**, deliberately a different variable from the user-facing opt-out;
   - `pgid = 0` (own process group — zigbase and rebuild children join it, so the group
     is killable as a unit);
   - `stdin = .ignore`, `stdout`/`stderr` = an opened `.zigbase/dev.log` (truncate on
     start). All dev output already goes to stderr via `std.debug.print`, so the log
     captures today's stream verbatim and no banner string changes.
2. Parent polls for the lockfile (200 ms interval, 30 s deadline) whose `pid` matches the
   child. Lockfile appearance ⇒ zigbase passed `waitReady` ⇒ server ready.
3. On success: print serve URL, control URL, PID, log path, and stop/status/logs hints;
   exit 0. On child death: print the log tail, exit 1. On timeout: SIGTERM the child's
   process group, remove any partial lockfile, print the log tail, exit 1.

The child runs the normal foreground path (the guard var short-circuits re-backgrounding,
including via agent detection) and records `background: true` in the lockfile.

### Lockfile

Path: `<site root>/.zigbase/dev.json` — beside `islands-manifest.json`, in the dir that is
created early and guaranteed outside every watched dir (writing it cannot retrigger the
watcher).

Written by **every** dev session (foreground and background) right after `waitReady`, where
the ready banner prints — ports are late-bound and unknowable earlier. Atomic write:
temp file + `rename`. **Amended:** the lifetime `flock(LOCK_EX)` is held on a separate,
create-once `.zigbase/dev.lock` — never on `dev.json` itself, and never unlinked. An
flock on `dev.json` would be orphaned by the atomic rename (the lock follows the open file
description, not the path), so holding it there would defeat the whole liveness scheme;
`dev.lock`'s own lifetime is independent of `dev.json`'s atomic replace.

Fields:

```json
{
  "version": 1,
  "pid": 12345,
  "zigbase_pid": 12346,
  "port": 1990,
  "url": "http://127.0.0.1:1990/",
  "control_port": 43121,
  "data_dir": "/abs/path/.zigbase",
  "background": true,
  "started_at": "2026-08-07T12:34:56Z"
}
```

- **Liveness = try-lock, not `kill(pid, 0)`.** The kernel drops the flock when the holder
  dies, so `status`/`stop`/duplicate-detection try a non-blocking `flock`: acquirable ⇒
  stale (auto-remove and treat as absent); busy ⇒ alive. No PID-reuse false positives, no
  `EPERM` misreads, no TOCTOU between check and write.
- A lockfile that fails field validation is treated as absent and removed.
- The signal handlers stay minimal (async-signal-safety bar set in `reaper`): **no cleanup
  on signal**. Stale-on-read detection makes cleanup-on-death unnecessary.

### Control server and build-aware status

`reload.Server` is promoted to the dev control server and always starts:

- `/` — the SSE live-reload stream, unchanged (client snippet, CORS, payloads intact).
- `GET /_zigapagos/status` — JSON, `access-control-allow-origin: *`:

```json
{
  "ok": true,
  "pid": 12345,
  "url": "http://127.0.0.1:1990/",
  "started_at": "2026-08-07T12:34:56Z",
  "build": {
    "generation": 7,
    "status": "ok",
    "duration_ms": 412,
    "error": null
  }
}
```

- `build.generation` is a monotonic counter bumped per completed rebuild (initial build =
  1). `build.status` ∈ `"ok" | "failed" | "building"`. `error` carries a bounded tail of
  the failed rebuild's output. The rebuild loop already owns all of this
  (`runRebuild`'s exit code and timing).
- The agent workflow this enables: edit a file → poll `/_zigapagos/status` until
  `generation` bumps → branch on `status` → read `error` or fetch the page. This is the
  feature's core differentiator; Astro's endpoint returns `{"ok": true}` and nothing else.
- `--no-live-reload` now means: no snippet injection, no reload/island events. The server
  itself, and the status endpoint, always run. The shared state (generation, last result)
  is a small mutex-guarded struct written by the watch loop and read by connection
  threads.

### `dev stop`

1. Read + validate the lockfile; try-lock says whether the dev process is alive.
2. Alive: SIGTERM the dev PID (the existing `reaper` cascades to zigbase), poll liveness
   every 100 ms up to 5 s, then escalate to SIGKILL — **amended:** of the dev PID, not the
   process group (a foreground `dev` shares the shell's own group, so a group-wide signal
   there would be wrong; the 30 s `--background`-startup-timeout path is the one that
   legitimately targets a group, since it owns one).
3. **Orphan sweep** (runs even when dev is already dead — the `kill -9` case): if
   `zigbase_pid` is alive, confirm it is really our zigbase by hitting
   `http://<host>:<port>/api/health` (zigbase's existing endpoint); on match, SIGTERM →
   SIGKILL it. This retires the documented "`pkill zigbase`" recovery.
4. Always remove the lockfile. Nothing to stop is a friendly no-op, exit 0 (idempotent).

`dev status`: lockfile + try-lock; when alive, also fetch `/_zigapagos/status` and print
URL, PID, `started_at` (**amended:** the timestamp, not a computed uptime), background
marker, and last-build state (`--json` for the raw object, with `"running": false` and
exit 1 when nothing is up).

`dev logs [--follow]`: print `.zigbase/dev.log`; `--follow` is a stat-offset polling tail
that flushes remaining bytes and exits when the dev PID dies. `logs` for a foreground
session (lockfile says `background: false`) explains that output is in that terminal,
exit 1.

### Agent auto-detection

A Zig table ported from `am-i-vibing`'s **agent-type** entries only — env-var checks, no
process-ancestry sniffing, and no hybrid/interactive entries (Astro's Warp false-positive
lesson). Representative signals: `CLAUDECODE`, `CODEX_THREAD_ID`, `CURSOR_TRACE_ID` +
`PAGER="head -n 10000 | cat"`, `GEMINI_CLI=1`, `CODEIUM_EDITOR_APP_ROOT`,
`AGENT`/`AI_AGENT` generics. **Amended:** `REPL_ID` is deliberately excluded from the
shipped table — it is an ambient platform variable Replit sets for human users too, not
an agent signal.

- Detection applies to `zigapagos dev` (and alias) only — never to sub-verbs, never when
  `ZIGAPAGOS_DEV_BACKGROUND_CHILD` is set.
- Detected agent ⇒ behave as if `--background` was passed, and say so in the parent's
  output ("agent environment detected (CLAUDECODE) — starting in background;
  ZIGAPAGOS_DEV_BACKGROUND=0 to disable").
- Opt-out: `ZIGAPAGOS_DEV_BACKGROUND=0` (any non-empty value other than `1` disables
  auto-detection; `=1` forces background). Distinct from the child guard var, so opting
  out cannot corrupt lockfile state.

### Conventions for zigbase (portability, not v1 work)

If zigbase ever grows `serve --background` for standalone dev use, it adopts these as-is
rather than inventing a second pattern:

- Lockfile: same field names (`version`, `pid`, `port`, `url`, `background`,
  `started_at`), same atomic write, same flock-held-for-lifetime liveness.
- Same verb shape (`stop|status|logs [--follow]`), same idempotency rules, same
  `--ignore-lock` semantics and conflicts.
- Same two-variable rule: internal recursion guard ≠ user-facing opt-out.
- Same readiness handshake: lockfile appears only when the server is actually serving.

## Error handling summary

| Situation | Behavior |
|---|---|
| Lockfile corrupt / fails validation | treat as absent (**amended:** proactive removal happens only on the stale-but-parseable row below; a corrupt `dev.json` is left in place — harmless, since every reader treats it as absent and a new session's atomic write overwrites it) |
| Lockfile stale (flock acquirable) | auto-remove, proceed |
| `--background`, live instance | print existing URL/PID, exit 0 |
| `--background`, child dies pre-ready | log tail to stderr, exit 1 |
| `--background`, 30 s timeout | SIGTERM group, remove lockfile, log tail, exit 1 |
| `stop`, nothing running | "No dev server is running.", exit 0 |
| `stop`, dev dead but zigbase orphaned | health-verified kill, remove lockfile, exit 0 |
| `status`, nothing running | message / `{"running": false}`, exit 1 |
| `logs`, foreground session | point at the owning terminal, exit 1 |
| `--ignore-lock` + `--background`/`--force` | conflict error, exit 1 |
| Lockfile write fails | warn and keep serving (bookkeeping never kills a healthy server) |

## Testing

- **Unit** (`src/cli/dev_control.zig`, tests named `"dev …"` for the `test-dev` filter,
  with the required lazy-analysis anchor in `src/main.zig`): lockfile round-trip +
  field validation + atomic write; staleness via flock in a spawned helper; sub-verb and
  flag parsing incl. the `--ignore-lock` conflicts; agent-table sniffing with a
  controlled env map.
- **e2e** (`tests/dev/`, hermetic via `stub-zigbase.ts`): full background lifecycle
  (start → status → edit file → status shows generation bump → logs → stop, port freed);
  duplicate-start idempotency + `--force`; orphan recovery (kill −9 dev, `stop` reaps the
  stub, lockfile gone); agent-env auto-background + `ZIGAPAGOS_DEV_BACKGROUND=0` opt-out;
  status endpoint present under `--no-live-reload`; ready-banner strings unchanged
  (existing greps keep passing).
- Regression tests verified to **fail without the fix** (repo rule).
- `changelog.d/<slug>.md` fragment; `docs/ROADMAP.md` entry; user-facing docs section for
  the new verbs and the agent workflow (poll-the-generation loop) — also feeds the future
  init-generated `AGENTS.md` (issue #131).

## Out of scope

- `dev wait` (block until debounce + in-flight rebuild settle, exit with build result) —
  v1.1, the design leaves room: it is a control-verb client of `/_zigapagos/status`.
- NDJSON structured log events + `logs --json` — v1.1, aligned with `docs/diagnostics.md`.
- Log rotation, restart-on-crash, any supervisor process.
- Windows (0.17 port), and anything resembling a proxy in front of zigbase (removed
  deliberately, issue #56).
