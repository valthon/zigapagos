# Working on this application

This frontend-only Zigapagos starter uses ordinary CSS and a Preact SPA.
Humans and coding agents use the same commands:

- `bun install` installs the project dependencies; commit `bun.lock`.
- `bun run check` typechecks the application.
- `bun run build` performs the production release into `public/`.
- `bun run dev` serves the application and rebuilds as you edit.
- `zigapagos doctor public --strict` audits emitted HTML links.

The build/dev scripts set the runtime location from the installed `@z/runtime`
file dependency. `ZIGAPAGOS_BIN` can select an absolute binary path. See README
for npm/npx usage and moving the local runtime link to another machine.

Edit `app/app.spa.tsx` for routes and UI, `app/storage.ts` for persistence,
`assets/style.css` for ordinary styles, and `content/index.smd` for the static
homepage. Do not edit `public/` by hand.

Storage is browser-local demonstration data, not a production backend. Do not
claim sign-in, authorization, backup, synchronization, or cross-user isolation.
Do not read browser globals during module initialization or server rendering.
Keep failed reads and writes visible, preserve drafts, and do not overwrite
corrupt data to make a test pass. Connecting an API requires server-side
identity, authorization, validation, and a concurrency policy.

Verify navigation, reload/deep links, keyboard form validation, read/write error
recovery, persistence, and the script-free static homepage in a real browser.
Use ordinary CSS or add a framework/design system deliberately; none is required.
