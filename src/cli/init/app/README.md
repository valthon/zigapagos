# Browser-local application starter

This is a frontend-only task application: ordinary CSS, Preact components,
client-side navigation, a labelled form, and loading/empty/error states.
`/` remains a static page without application JavaScript. `/app/`, `/app/new/`,
and `/app/about/` have prerendered HTML shells.

## Install and run

You need Bun and Zigapagos on PATH. For a downloaded standalone binary, supply
runtime sources when scaffolding:

```sh
zigapagos init --app --runtime-path=../zigapagos/runtime
bun install
bun run check
bun run build
bun run dev
```

Install the runtime's own dependencies first (`cd ../zigapagos/runtime && bun
install --frozen-lockfile`). The npm Zigapagos launcher supplies its bundled
runtime location automatically when running `init --app`; no explicit path is
needed in that case. If you only use `npx zigapagos`, it does not install a global
command: use `npx zigapagos release --spa='app/app.spa.tsx|/app' --force` and
`npx zigapagos dev` instead of the build/dev scripts.
The scripts also accept an absolute `ZIGAPAGOS_BIN` executable path.

`package.json` contains a **local file dependency** for `@z/runtime`. The printed
runtime link is relative when discovered from the environment; an explicit path
is preserved. This depends on your workspace layout or npm installation/cache.
It is not a portable published runtime version. Before moving this project or
running on another machine, install the matching runtime and update that file
link, then run `bun install`. Commit your generated `bun.lock`. Do not assume an
old npm cache path is permanent.

Open `/app/` on the dev server. Build output goes to `public/`.

## What is and is not persisted

`app/storage.ts` reads/writes one browser-local key: `zigapagos.tasks.v1`.
Storage runs only after mounting or submitting a form, never during SSR. A write
updates the interface only after storage succeeds. Corrupt or blocked storage
shows an error and never overwrites saved data during loading. Retry after
repairing the data or browser permissions. Do not clear storage blindly if you
need the saved tasks.

This is not authentication, server persistence, backup, multi-device sync, or
safe concurrent editing across browser tabs. Do not store sensitive information
in this demo. Data belongs to one browser and origin; changing the deployment
origin gives you a different store.

## Connect your existing backend

Replace the exported `storage` adapter while preserving its TypeScript contract:
`read(): Promise<Task[]>` and `write(tasks: Task[]): Promise<void>`. `Task` has
`id: string`, `title: string`, and `done: boolean`. Reject failed requests so the
UI retains the draft and offers retry. The local adapter is the only backend
implemented here. There is no hidden `/api` endpoint.

For a real API, use fetch in this adapter, validate responses, and enforce
identity, ownership, validation, authorization, and conflict handling on the
server. A whole-list replacement is suitable for this local demo, not a default
concurrent database protocol: prefer server-owned per-record mutations and
version checks for shared applications. Adapt the model before promising that
behavior. Pairing with ZigBase is documented separately in Zigapagos's guide.

## Verify and deploy

```sh
bun run check
bun run build
zigapagos doctor public --strict
```

Exercise create/complete/reload, keyboard navigation, invalid form input,
read/write failures, and retries in a browser. The Zigapagos repository runs
these journeys against fresh scaffolds in CI.

Set `host_url` in `zigapagos.ziggy`, then deploy `public/` to a static host that
serves directory `index.html` files. All three application routes are emitted
as real files. This starter assumes the domain root; update SPA base, navigation,
and stylesheet URLs together if deploying under a subpath. No application
server is needed for the browser-local demo.
