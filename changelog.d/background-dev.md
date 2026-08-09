### Added

- **`zigapagos dev --background`**: detach the dev loop as its own process
  group (stdio to `.zigbase/dev.log`), wait for it to actually become ready,
  then print its URL/PID/log path and exit 0 — no more babysitting a
  foreground `dev` from a script or an agent. `dev stop|status [--json]|logs
  [--follow]` manage it afterward; `--force` restarts an existing session,
  `--ignore-lock` runs a second, untracked instance. See `docs/dev-server.md`.
- **`GET /_zigapagos/status`**: the dev control server (formerly just the
  live-reload stream, now always on) reports the served URL/PID plus
  build-aware state — a monotonic `generation` counter, `status`
  (`ok`/`failed`/`building`), `duration_ms`, and a bounded `error` tail on
  failure — so an agent can poll for its own edit to land and branch on the
  result instead of guessing when a rebuild finished.
- **Agent auto-detection**: `zigapagos dev` backgrounds itself automatically
  in a recognized AI-agent environment (Claude Code, OpenAI Codex, Gemini
  CLI, Cursor's agent mode, and others — see the table in
  `docs/dev-server.md`). `ZIGAPAGOS_DEV_BACKGROUND=0` opts out;
  `ZIGAPAGOS_DEV_BACKGROUND=1` forces it even outside a detected environment.
- `dev stop` now reaps a zigbase left orphaned by a `kill -9`'d dev session
  (health-verified via zigbase's own `/api/health` before touching it),
  retiring the previously-documented manual `pkill zigbase` recovery.
