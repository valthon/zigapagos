> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/dev-server/> — the site is the canonical reading experience.

# Background dev server management

`zigapagos dev` normally blocks the terminal it was started in. `dev --background`
detaches it instead — a small feature aimed squarely at AI coding agents: edit
a file, poll a JSON status endpoint until a rebuild lands, act on the result,
all without a `dev` process pinning a terminal for the whole session.

This document is the consumer contract for the pieces a script or an agent
codes against: the CLI surface, the `/_zigapagos/status` JSON shape, and
`.zigbase/dev.json`'s fields.

## Foreground vs background

```sh
zigapagos dev                 # blocks this terminal; Ctrl-C stops it
zigapagos dev --background    # detaches, prints facts, exits 0
```

`--background` re-execs this same binary as a detached child (own process
group; `stdin` ignored; `stdout`/`stderr` redirected to `.zigbase/dev.log`,
truncated at the start of the session) and polls for the lockfile to appear
naming that child's pid — the same signal `waitReady` already gates the
ready banner on, so a zigbase that fails to boot fails background startup
the same way it fails a foreground run. The parent exits 0 **only once the
server actually answers**, printing:

```
dev: running in the background at http://127.0.0.1:1990/ (pid 12345)
dev: control:  http://127.0.0.1:43121/_zigapagos/status
dev: log file: /abs/path/.zigbase/dev.log
dev: manage:   zigapagos dev stop | status | logs [--follow]
```

- Child dies before becoming ready → parent prints the log tail, exits 1.
- 30 s pass with no readiness → parent SIGTERMs the child's whole process
  group, removes any partial lockfile, prints the log tail, exits 1.
- A live session is already running → `--background` is idempotent: it
  prints the existing URL/PID and exits 0. `--force` stops that session
  first (the same path as `dev stop`), then starts fresh. `--ignore-lock`
  starts an untracked instance — it never writes the lockfile, and always
  prints a notice that this instance is untracked (whether or not a tracked
  one already exists) — and hard-errors when combined with `--background`
  or `--force` (an untracked instance has no lockfile for `--background`'s
  own readiness handshake to poll).

## Sites with a `url_path_prefix`

A site with `url_path_prefix` set in `zigapagos.ziggy` (the documented setup
for a GitHub Pages *project* site, served from `https://user.github.io/repo/`
rather than the domain root — this repo's own `site/zigapagos.ziggy` uses it)
emits every href, asset link and island module URL under `/<prefix>/…`. The
built tree itself deliberately contains no prefix directory —
`url_path_prefix` says where a host *mounts* the tree, not where files sit
inside it (see [`docs/spa.md`](spa.md)) — so a plain root mount 404s every
one of those URLs.

`dev` (and `zigapagos e2e --url-prefix=`) handle this automatically: they
stage a served root that mounts the built tree at `/<prefix>/` — refreshed
after every rebuild — and point zigbase at that staged root instead of at
the tree itself, so local URLs resolve exactly like production. Nested
prefixes (`docs/v2`) work the same way.

Two knock-on effects, both by design:

- **`GET /` 404s.** The staged root's only real content lives under
  `/<prefix>/`, so there is no `index.html` at the served root. The
  readiness probe and the printed banner URL already account for this — both
  default to `/<prefix>/` instead of `/` when the site has a prefix — but a
  manually passed `--ready-path=/`, or a bookmark at the bare origin, still
  404s.
- **Unprefixed sites are completely unaffected.** No staging happens and
  zigbase serves the built tree directly, byte-identical to before this
  existed.

The staged copy lives at `.zigbase/.served-root/` and — deliberately — is
never cleaned up when `dev` exits: it shares the (persistent, gitignored)
zigbase data dir's own lifecycle, so the next `dev` session reuses the
directory and just re-stages into it, the same way `.zigbase/` itself is
never deleted between sessions.

## Control verbs

```sh
zigapagos dev stop
zigapagos dev status [--json]
zigapagos dev logs [--follow|-f]
```

Every sub-verb accepts `--data-dir=DIR` (same meaning as `dev`'s own flag)
and must be run from the site directory — they resolve the data dir against
`zigapagos.ziggy` the same way `dev` itself does.

**`dev stop`** — idempotent: nothing running is a friendly no-op, exit 0. A
live session gets SIGTERM on the dev **pid** (the existing `reaper` — the
signal handler dev installs on boot — cascades that into its own tracked
zigbase child), polled for up to 5 s, escalated to SIGKILL of that same dev
pid if it doesn't respond. Neither signal targets a process group here —
that's `--background`'s 30 s startup-timeout path, not `stop`'s — which
matters because a SIGKILLed dev process never runs the reaper at all, and
its zigbase is left orphaned on the port. That is exactly why the **orphan
sweep** runs afterward regardless: if the lockfile's `zigbase_pid` is still
alive, `stop` confirms it is really our zigbase by hitting its
`/api/health`, then TERMs/KILLs it — covering whatever the reaper missed
(or never ran to cover). This is what retires the documented `pkill
zigbase` recovery for a `kill -9`'d dev session. One case exits 1 instead
of 0: a session that holds the lock but hasn't published `dev.json` yet
(mid-startup) — `stop` reports that truthfully rather than silently doing
nothing.

**`dev status`** — exit 0 with the session's facts when one is running,
exit 1 ("No dev server is running." or `{"running":false}` under `--json`)
when not. A third, in-between state: a session can hold the lock but not
have published `dev.json` yet — the same startup window `dev stop` already
reports as its own `.starting` case (see above) — and `status` reports it
truthfully rather than folding it into "not running": exit 1, "A dev
session is starting (lock held, dev.json not yet published) — retry in a
few seconds." on stdout, or `{"running":false,"starting":true}` under
`--json`. `status` never polls/blocks to resolve this — it is a snapshot
verb, so it reports whatever it sees on one immediate read and lets the
caller retry. When the control endpoint can't be reached for a session that
*has* published `dev.json` (e.g. it's still warming up), status degrades
gracefully instead: it still prints from the lockfile alone, with `build:
unknown (control server unreachable)`.

**`dev logs [--follow]`** — prints `.zigbase/dev.log`. A **foreground**
session has no log file to read — its output is in the terminal that
started it — so `logs` points there and exits 1. `--follow`/`-f` stat-polls
for new bytes every 200 ms and exits once the session's lock is no longer
held. Reads are capped at 16 MiB; past that, `logs` fails with a message
pointing at reading the file directly (`tail -f`).

## The status endpoint

`GET http://127.0.0.1:<control_port>/_zigapagos/status` — the same server
that already serves the SSE live-reload stream, now always on (even under
`--no-live-reload`, which disables only snippet injection and reload
events). CORS is wide open (`access-control-allow-origin: *`), same as the
reload stream.

```sh
curl -s http://127.0.0.1:43121/_zigapagos/status | jq .
```

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

| field | type | meaning |
| --- | --- | --- |
| `ok` | bool | always `true` — the endpoint answered |
| `pid` | int | the dev process's pid |
| `url` | string | the served site's URL |
| `started_at` | string | ISO-8601 UTC, session start |
| `build.generation` | int | monotonic counter, bumped once per completed rebuild (the initial build is generation 1) |
| `build.status` | `"ok"` \| `"failed"` \| `"building"` | outcome of the most recently *finished* rebuild, or `"building"` while one is in flight |
| `build.duration_ms` | int | how long that rebuild took |
| `build.error` | string \| null | a bounded tail of the failed rebuild's captured output, `null` on success |

`generation` bumps on **both** success and failure — an agent polling for
its own edit to land needs the counter to move either way, and only then
branches on `status`.

**The agent workflow this is for:**

1. Edit a file.
2. Poll `/_zigapagos/status` until `build.generation` is greater than the
   value observed before the edit.
3. Branch on `build.status`: `"ok"` → fetch the page; `"failed"` → read
   `build.error`; `"building"` → keep polling.

This is deliberately more than Astro's equivalent endpoint, which returns
only `{"ok": true}` and gives an agent nothing to act on.

## The lockfile

`.zigbase/dev.json` — written by every dev session, foreground and
background, immediately after `waitReady` (ports are late-bound, so nothing
sooner is knowable). Written atomically (temp file + rename). Treat it as a
**read-only** contract: `dev` owns it, tooling only reads it.

```json
{
  "version": 1,
  "pid": 12345,
  "zigbase_pid": 12346,
  "host": "127.0.0.1",
  "port": 1990,
  "url": "http://127.0.0.1:1990/",
  "control_port": 43121,
  "data_dir": "/abs/path/.zigbase",
  "background": true,
  "started_at": "2026-08-07T12:34:56Z"
}
```

| field | meaning |
| --- | --- |
| `version` | lockfile schema version (currently `1`) |
| `pid` | the dev process |
| `zigbase_pid` | the zigbase child dev spawned |
| `host` | the session's `--host` (default `127.0.0.1`) — the bind address for both `port` and `control_port` |
| `port` | the served site's port |
| `url` | the served site's URL |
| `control_port` | the `/_zigapagos/status` port |
| `data_dir` | absolute path to the ZigBase data dir |
| `background` | `true` for a `--background` session, `false` for foreground |
| `started_at` | ISO-8601 UTC |

**Liveness is a try-lock, not a pid check.** `.zigbase/dev.lock` is an empty
file the dev process holds `flock(LOCK_EX)` on for its whole lifetime; the
kernel drops that lock the instant the process dies, by any means, including
`kill -9`. `status`/`stop`/duplicate-start detection all attempt a
non-blocking `flock`: acquirable → stale (remove `dev.json`, treat as
absent); busy → a live session really is there. This sidesteps both of
`kill(pid, 0)`'s failure modes — PID reuse reading as "alive", and `EPERM`
(alive, just not ours) reading as "dead". `dev.lock` itself is **never
deleted** — unlinking a file another process still holds an flock on does
not release that lock, it just lets a second lockfile of the same name
coexist and defeats the whole liveness scheme.

`.zigbase/dev.log` — a background session's `stdout`+`stderr`, truncated at
the start of each `--background` session (the same content a foreground run
prints to its terminal — no banner strings changed to make this work).

`.zigbase/last-build.log` — captured fresh on every rebuild in the watch
loop, purely as the source for `build.error`'s tail on a failed build; the
initial build streams straight to the terminal/log and is never captured
here.

## Agent auto-detection

Detected agent environments get backgrounded automatically — the same idea
as Astro's `astro dev --background`, ported from the same
`am-i-vibing`-shaped table: env-var checks only, no process-ancestry
sniffing, and no hybrid/interactive entries (a Warp-the-terminal false
positive was Astro's own first post-release fix for this).

| env var | provider |
| --- | --- |
| `CLAUDECODE` | Claude Code |
| `CODEX_THREAD_ID` | OpenAI Codex |
| `GEMINI_CLI` | Gemini CLI |
| `CODEIUM_EDITOR_APP_ROOT` | Windsurf |
| `AIDER_API_KEY` | Aider |
| `OZ_RUN_ID` | Warp agent |
| `AMP_CURRENT_THREAD_ID` | Amp |
| `AUGMENT_AGENT` | Auggie |
| `QWEN_CODE` | Qwen Code |
| `ANTIGRAVITY_AGENT` | Antigravity |
| `PI_CODING_AGENT` | Pi |
| `OPENCODE` | OpenCode |
| `CRUSH` | Crush |
| `CURSOR_TRACE_ID` + `PAGER=head -n 10000 \| cat` | Cursor agent |
| `AGENT` (any non-empty value) | `agent (AGENT env)` |
| `AI_AGENT` (any non-empty value) | `agent (AI_AGENT env)` |

An empty value never counts (an exported-but-unset shell variable is not a
signal); `CURSOR_TRACE_ID` alone is the interactive terminal, not an agent —
only paired with the agent-mode `PAGER` rewrite does it count.

Detection applies to `zigapagos dev` only — never to a sub-verb, and never
when `ZIGAPAGOS_DEV_BACKGROUND_CHILD` is set (see below). A detected agent
backgrounds exactly as if `--background` had been passed, and the parent
says so: `dev: agent environment detected (Claude Code) — starting in the
background (set ZIGAPAGOS_DEV_BACKGROUND=0 to disable)`.

- **`ZIGAPAGOS_DEV_BACKGROUND=0`** (or any value other than `1`) disables
  auto-detection. `=1` forces background regardless of detection.
- **`ZIGAPAGOS_DEV_BACKGROUND_CHILD`** is internal — the recursion guard set
  on the re-exec'd child so it runs the plain foreground path instead of
  backgrounding itself again. Deliberately a separate variable from the
  opt-out above: conflating the two (as Astro does) means opting
  out corrupts the child's own lockfile `background` field.

Precedence (checked in this order — the first match decides, nothing later
is consulted): the recursion guard (`ZIGAPAGOS_DEV_BACKGROUND_CHILD`) forces
foreground unconditionally; short of that, an explicit `--background` wins
outright, with no provider attribution; short of that, `--ignore-lock`
suppresses auto-detection entirely (an untracked instance has no lockfile
for the readiness handshake to poll); short of that, the opt-out env is an
explicit override (`=1` backgrounds, anything else foregrounds); only then
does agent detection get to decide, and only then is a provider ever
attributed in the parent's output.

## Conventions for ZigBase (portability, not v1 work)

If zigbase ever grows `serve --background` for standalone dev use, it adopts these as-is
rather than inventing a second pattern:

- Lockfile: same field names (`version`, `pid`, `port`, `url`, `background`,
  `started_at`), same atomic write, same flock-held-for-lifetime liveness.
- Same verb shape (`stop|status|logs [--follow]`), same idempotency rules, same
  `--ignore-lock` semantics and conflicts.
- Same two-variable rule: internal recursion guard ≠ user-facing opt-out.
- Same readiness handshake: lockfile appears only when the server is actually serving.

## Out of scope / v1.1

- **`dev wait`** — block until the debounce window and any in-flight rebuild
  settle, then exit with the build's result. Deferred to v1.1: the design
  leaves room for it since it is just another control-verb client of
  `/_zigapagos/status`.
- **NDJSON structured log events + `logs --json`** — v1.1, aligned with
  [`docs/diagnostics.md`](diagnostics.md)'s NDJSON convention.
- **Log rotation, restart-on-crash, any supervisor process** — not planned;
  `dev --background` is one detached process, no daemon.
- **Windows** rides the Zig 0.17 port (see [`docs/ROADMAP.md`](ROADMAP.md));
  anything resembling a proxy in front of zigbase was removed deliberately
  (issue #56) and is not coming back.
