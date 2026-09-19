# Building applications with Zigapagos

Zigapagos's mission is rich interfaces with simple output: familiar web languages,
fast production builds, and static files you can deploy. Output correctness and
browser efficiency come first. Tooling should make that result easy to build and
inspect, whether you write every line or work with a coding agent.

The native core generates HTML and Bun renders and bundles TSX at build time.
Pages without islands need no framework runtime. Full application routes can use
a native SPA; personalised data still comes from a backend API. Static output
simplifies frontend hosting without claiming the entire application is static.

## Bring your styles and components

Start with HTML templates and ordinary CSS. Zigapagos does not require a CSS
framework, utility-class vocabulary, theme, or design system. When you choose a
stylesheet compiler, run it before `zigapagos release` and stage its CSS output
as a site asset. Use the same approach for a design system's styles and fonts;
keep asset URLs valid for the deployed directory and URL prefix.

SuperHTML adds template directives, SuperMD supplies content syntax, and Ziggy
configures the project. These are explicit conventions rather than a claim of
zero special syntax. See [templates](superhtml.md), [assets](assets.md), and
[islands](islands.md). Preact compatibility must be checked for component libraries;
a CSS-only library does not need a JavaScript compatibility layer.

## Build and ship

Generate the release directory, inspect it, then deploy those files to a compatible
static host. The frontend needs no production Node or Bun runtime. For SPA routes,
apply the host's fallback configuration; configure cache and CSP headers and verify
deep links after deployment. The [SPA reference](spa.md) documents the emitted
host configuration. Custom CSS generation belongs before the release command,
not on the production server.

Fast production builds are a priority, not a universal timing claim. Measure the
same project, tool versions, and cold/warm state when comparing changes. Image
processing, type checking, and component rendering can dominate a site's build.

## Choose the application shape

- **Frontend only:** build content pages, TSX islands, or a native SPA against your
  existing backend. Deploy the release tree to a compatible static host; configure
  SPA fallback, security headers, and caching for that host. ZigBase is used by
  the local dev and e2e commands, but is not required as your production backend.
- **Paired with ZigBase:** serve the frontend and API on one origin. ZigBase owns
  data, validation, authentication, authorization, files, realtime, jobs, and
  trusted business operations. Use its stock server or extend its Zig framework.
  A custom Zig backend needs the Zig toolchain; building the frontend does not.
- **Content site:** use templates and SuperMD with selective islands. An account
  system or application backend is unnecessary when the product does not need one.

See [islands](islands.md) and [native SPAs](spa.md). Preact-compatible TSX is the
component model; compatibility with an arbitrary React package is not guaranteed.
Zigapagos renders components at build time, not per request. Fetch personalised
application data through your backend's authenticated API.

## Work directly or with an agent

Power users control source, templates, styles, route definitions, hydration, and
host configuration. No AI service or subscription is required. Agents use the
same interfaces, with scaffolded project instructions and
[structured diagnostics](diagnostics.md) to make failures actionable.

A useful frontend verification loop is:

```sh
zigapagos validate --format=json
zigapagos release --format=json --output=public --force
zigapagos doctor public --format=json
```

`validate` is a fast subset, not a full build. `doctor` checks the emitted static
tree; it cannot prove backend permissions or browser interactions. Add browser
journeys for your application and backend allow/deny tests for protected actions.
The [dev server](dev-server.md) supports background status and logs for either a
person or an agent; [testing](testing.md) describes built-tree assertions.

## The ZigBase boundary

| Concern | Owner |
| --- | --- |
| Pages, layouts, islands, navigation, frontend assets | Zigapagos |
| API transport and backend auth state | ZigBase client SDK |
| Data validation, access rules, trusted state transitions | ZigBase |
| Browser loading, error, empty, and session-expiry presentation | Application frontend |
| Deployment, capacity, backup and recovery verification | Application team |

A hidden button or client route guard is presentation, not authorization. Enforce
protected operations in ZigBase rules or custom routes and test allowed and denied
cases. Keep server credentials out of generated frontend assets.

Follow the canonical [ZigBase pairing guide](https://github.com/valthon/zigbase/blob/main/docs/zigapagos-pairing.md)
and its [Blog reference application](https://github.com/valthon/zigbase/tree/main/examples/blog).
They cover independent scaffolds, the custom backend binary, same-origin cookies,
typed clients, layered tests, and deployment. Pin both projects' versions and use
the guide matching your ZigBase revision. A stock dev binary cannot supply a
custom application's compiled hooks, routes, or jobs.

[Cross-tier codegen](cross-tier-codegen.md) describes Zigapagos's integration
mechanisms. Enable the backend's appropriate generation mode and verify against
its authoritative schema; committed types alone do not establish contract parity.

## What is available and what comes next

Pages, islands, SPA routing, diagnostics, local dev tooling, and documented pairing
are available. Plain `zigapagos init` still creates a content site. Application
forms, UI conventions, and backend integration require deliberate assembly today.
The [feature backlog](ROADMAP.md) prioritizes a paired starter, reusable frontend
patterns, reliable feedback, and evaluations of evolving real applications.

Zigapagos is pre-1.0. Assess library compatibility and test upgrades. The combined
platform aims to make a small team productive as its application grows; capacity
must be established with representative workloads. Follow ZigBase's deployment
and growth guidance for database changes, replicas, shared files, and job ownership.
Frontend bundle size or a fast native build is not proof of backend scalability.

## Browser-local application starter

`zigapagos init --app` creates a task application at `/app/`, with an ordinary-CSS
static landing page, navigation, a labelled form, loading/empty/error states,
and typed asynchronous storage. Its generated README contains install, check,
build, dev, and deployment commands. The npm launcher supplies runtime sources;
a standalone binary needs `--runtime-path=DIR`. Generated `@z/runtime` is a local
file dependency, not a portable package version: preserve the documented
workspace layout or update the link on another machine.

This is an immediately runnable frontend example. It persists only in browser
localStorage, provides no authentication, and makes no shared-data guarantees.
The storage module documents the `read`/`write` adapter contract for connecting
your own backend. A production adapter also needs validated responses,
authoritative authorization, and per-record/concurrent mutation semantics;
replacing localStorage with a whole-list HTTP write is not sufficient.

The fresh-scaffold checks build outside the repository, typecheck the app, and
exercise keyboard validation, failed reads/writes, retry, reload, deep links,
corrupt-data preservation, and the static landing page in Chrome. Broader
API-backed and ZigBase-paired starter work remains on the roadmap.
