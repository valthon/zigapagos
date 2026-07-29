# DX backlog — findings from building the marketing site

This backlog comes from one real project: building the Zigapagos marketing and
documentation website *with Zigapagos*. Thirteen tasks, 41 commits, roughly
thirty review findings. It is not a wishlist — every item below is tied to a
delay, a workaround, or a defect that actually happened, with the cost it
imposed and a concrete fix.

The site is a fair proxy for a real consumer: a nine-section landing page, 14
documentation pages (nine generated from canonical markdown), three interactive
demos, a native SPA, and a deploy to GitHub project pages under a
`url_path_prefix`.

Items are `DX-n` and are filed as issues #20–#44; each heading links its number.

## The headline

**The expensive failures were silent, not loud.** Build errors cost minutes;
every one of them was a message we read, understood, and fixed. What cost hours
was code that *compiled and produced wrong output*: a nav where every item
claimed to be the current page, a nested layout that rendered an empty box, a
demo whose every link was dead, a 404 page that never replaced the one it was
written to replace.

A build that fails is a good day. Six of the seven P0 items below are cases
where Zigapagos accepted something meaningless and emitted something wrong.

## What already works well

Worth recording, because it shapes what is worth changing:

- **Static syntax highlighting** produced correct output for every language we
  used, with no client-side cost.
- **`$page.toc()`** gave the documentation site's on-this-page navigation for
  free — 61 entries on the largest page, from generated heading ids.
- **Inline `:props` with a Ziggy struct** handled arrays of objects with nested
  quotes and newlines on the first attempt, and the `tsc` props gate
  (`src/islands/props_check.zig`) is real — it generates a program importing
  each island's exported `Props` and parses real diagnostics.
- **The pass ordering** genuinely limits blast radius. SPA validation running
  before the page pass meant every bad SPA declaration we wrote aborted before
  the output tree was touched.
- **Asset URL prefixing** under `url_path_prefix` was correct everywhere we
  looked except one place (DX-6), across 389 internal links.
- **Build times** stayed near two minutes for the full site including a SPA,
  four islands and 14 documentation pages.

---

## P0 — Silent wrong output

A green build that produced incorrect HTML. These are the highest-value fixes
in this document.

### DX-1 · [#20] `:if` on a real element is not conditional, and `:else` does nothing

**What happens.** For a plain element, `superhtml/src/template.zig` writes the
open tag *and every attribute* before `skip_body` is consulted — so
`:if="false"` on `<a aria-current="page">` still emits the tag and the
attribute, and only the children are skipped. Separately, `:else` is
parse-validated and then never read at evaluation time, so its body always
renders.

**What it cost.** The documentation sidebar shipped `aria-current="page"` on all
14 navigation items. The build was green. It was caught only by reading the
emitted HTML, then confirmed against `template.zig`.

**Fix (capability).** Make this a parse error. If `:if` on a non-`<ctx>` element
cannot conditionally emit the element, reject it with a message naming
`<ctx :if="…">` as the construct that does. Likewise reject `:else` outright
until it is implemented — an attribute that validates and then silently does
nothing is worse than one that does not exist.

**Fix (docs).** State the `<ctx>` rule wherever conditionals are documented.

---

### DX-2 · [#21] `.aliases` entries are section-relative unless they start with `/`

**What happens.** `src/worker.zig` treats an alias as root-absolute only when it
begins with `/`. `"404.html"` resolves to `<page-url>/404.html`.

**What it cost.** A content page aliased to `404.html` — written specifically to
override a SPA's site-wide fallback — landed at `404/404.html` instead. The
build passed, and the demo application went on owning the real site root. The
step existed to stop a mistyped URL dropping a visitor into a toy app, and as
written it silently did not.

**Fix (capability).** Warn when an alias's basename matches a known site-wide
artifact (`404.html`, `index.html`, `robots.txt`) but the alias is not
root-absolute — that combination is almost always a mistake. Alternatively,
print resolved alias destinations at `--verbose`.

**Fix (docs).** One sentence where `.aliases` is documented. The rule is not
currently stated anywhere.

---

### DX-3 · [#22] Layout-route components receive no `children`

**What happens.** The router renders a layout rung as `h(comp, {})`
(`runtime/src/router.ts`). `<Outlet/>` is the only channel by which a layout
receives its child route. A layout written as
`<div>{children}</div>` compiles, renders, and produces an empty container.

**What it cost.** The SPA demo's nested layout rendered an empty dashed box, and
three route components were dead code that never executed. The prerendered shell
was byte-identical to the empty template. Caught in review, not by any gate.

**Fix (capability), in order of preference:**
1. Pass `children` in addition to providing `<Outlet/>`. Every developer
   arriving from React or Preact will reach for `children` first, and there is
   no reason both cannot work.
2. Failing that, warn in dev builds when a component used as a layout route
   renders without an `<Outlet/>` in its output.

**Fix (docs).** `docs/spa.md`'s nested-routes section should open with "a layout
component receives no `children` prop" rather than showing `<Outlet/>` and
leaving the reader to infer it is mandatory.

---

### DX-4 · [#23] `<Link>` outside a Router silently degrades to a plain anchor

**What happens.** With no router context, `<Link>` renders its `href` verbatim
and does not intercept clicks.

**What it cost.** Every navigation link in the SPA demo was dead. The chrome was
a JSX wrapper *around* `<Router>` rather than a layout route inside it — a
natural way to write it — so the emitted shells contained `href="/guides"`
instead of the resolved route, which on a project-pages host is a hard 404. The
demo's own footer claimed every link navigated without a page load. Nothing in
it did.

**Fix (capability).** Warn (dev) or throw (dev) when `<Link>` renders with no
router context. This is unambiguous: a `<Link>` outside a Router is never
intentional.

---

### DX-5 · [#24] SPA shells load no stylesheet unless `spa.head` is used

**What happens.** A SPA shell's `<head>` is fixed: import map, modulepreloads,
boot script. Site stylesheets are not inherited.

**What it cost.** The demo reached from the landing page's primary call to
action rendered as unstyled default HTML, visually unrelated to the rest of the
site. Every CSS rule written for it was dead. `spa.head` is documented and does
the job properly — including staging the asset so a missing file is a build
error — but nothing pointed at it.

**Fix (capability).** Warn at build time when a site has stylesheet assets and a
declared SPA has no `spa.head` stylesheet entry. Or scaffold one in `init`.

---

### DX-6 · [#25] `$site.asset(...).link()` cannot produce an absolute URL

**What happens.** `printAssetUrlPrefix` (`src/render/html.zig`) emits `host_url`
only when `ctx.page != page`, and `Asset.link()`'s `.site` branch always passes
`page == ctx.page`. There is no usage of `.link()` from a page's own template
that yields an absolute URL.

**What it cost.** `og:image` shipped as `/zigapagos/og.png`. Open Graph requires
absolute URLs and several scrapers do not resolve relative ones, so the social
card — built specifically to work — would have rendered blank everywhere it
mattered. The fix is `$site.host_url.addPath($site.asset('og.png').link())`,
with `.link()` kept nested so the asset's install refcount still bumps.

**Fix (capability).** Provide `$site.asset(...).absLink()`, or make `.link()`
context-aware. The nesting requirement above is a trap in its own right: drop
the inner call and the asset is silently pruned from the output.

**Fix (docs).** `docs/` already states that `host_url` is "the origin used to
build absolute URLs — canonical links, feeds, and social metadata". The
mechanism was documented; the fact that `.link()` cannot do it was not.

**Consider also:** a build-time warning for a root-relative `og:*` or canonical
URL. It is never correct.

**Resolved.** `$site.asset(...).absLink()` / `$page.asset(...).absLink()` now
exist (`src/context/Asset.zig`), sharing `link()`'s install-refcount-bumping
body via `linkImpl` so the two builtins cannot drift out of sync. The
build-time warning is deferred to the `doctor` subcommand (#41) — the render
pass never sees a finished attribute as "this is an og tag", so it can only
ever be a lint, not a build invariant. Regression fixture:
`tests/rendering/abs-link/`.

---

### DX-7 · [#26] `url_path_prefix` is not threaded into `Router.base`

**What happens.** The runtime exports no path prefix. The AUDF-005 work prefixes
shell *asset* URLs but never the Router's base. The build's SSR pass simulates
each route at an unprefixed pathname (`ssr_pathname` in `src/spa.zig`) while a
real browser has the prefix in `location.pathname`. One `base` literal cannot
satisfy both.

**What it cost.** SPA navigation links render base-relative in prerendered
shells. Clicks resolve correctly because the handler recomputes the target, but
the visible `href` is wrong and the links are dead without JavaScript. The site
now discloses this in the demo itself.

**Fix (capability).** Inject the prefix as a build-time constant threaded
through both the sidecar SSR pass and the client bundle, so `Router.base` can
differ between the two environments without the author choosing. Three
independent reviews confirmed there is no author-side workaround.

This is the one item where a consumer cannot route around the gap.

---

## P1 — Loud failures that cost disproportionate time

### DX-8 · [#27] `$site.page()` hard-fails on a page that does not exist yet

**What it cost.** More than any other single item. Incremental authoring is
impossible: adding a navigation link before its target exists breaks the build,
so we created roughly eight placeholder content files purely to keep it green,
then deleted or overwrote them later. One placeholder collided with a generated
filename and had to be untracked separately, because git does not untrack a file
merely because it becomes ignored.

**Fix.** A `--allow-missing-pages` flag, or a warning in dev and an error in
release. A site under construction always has dangling internal links; that is
what "under construction" means.

---

### DX-9 · [#28] The subpage-vs-relative link trap has a misleading error

**What happens.** In SuperMD a leading `.` in a link target means "subpage of
this section", not "relative path". A page that is not a section fails with
`this page has no subpages (page is not a section)`
(`src/context/Page.zig:163`).

**What it cost.** 55 build errors when publishing existing markdown, and a
redesign of the link-rewriting strategy. The message describes a property of the
current page and never hints that the *link syntax* is what was misread.

**Fix (docs + message).** Extend the error: "a leading `.` in a link target
means subpage-of-section; for a sibling page use `$link.page("…")`". A message
that names the fix would have saved most of that time.

---

### DX-10 · [#29] No heading auto-slugification

**What happens.** SuperMD does not generate heading ids. Existing markdown
written for GitHub — which does — arrives with anchors pointing at nothing.

**What it cost.** 32 `unknown ref` errors, and a GitHub-compatible slug
algorithm written into the site's generator, including matching GitHub's
double-hyphen behaviour around em-dashes. That algorithm is now site-specific
code that every other consumer importing markdown will have to rewrite.

**Fix (capability).** An opt-in `auto_heading_ids` site setting producing
GitHub-compatible slugs, with the existing `$heading.id(...)` remaining as the
explicit override. This is close to table stakes for adopting a project's
existing documentation.

---

### DX-11 · [#30] Raw HTML is forbidden in `.smd` with no escape hatch for islands

**What happens.** SuperMD rejects `HTML_BLOCK` and `HTML_INLINE` nodes
outright, so `<island>` cannot appear in content — only in `.shtml` layouts.

**What it cost.** Structural. Every marketing page became a thin frontmatter
file plus a bespoke per-page layout, because any page wanting one interactive
component needs a layout to host it. The site has nine layouts largely for this
reason. It also means prose and the component embedded in that prose live in two
different files.

**Fix (capability).** A SuperMD island directive — something in the shape of
`[]($island.src("components/X.island.tsx").client("visible"))` — would remove
the single largest source of layout proliferation and let documentation pages
embed live examples inline. This is the highest-leverage *feature* request in
this document.

The strictness itself is right, and worth keeping: it is why generated
documentation cannot silently degrade.

---

### DX-12 · [#31] Unknown code-fence languages are fatal and undiscoverable

**What it cost.** `jsonc` and `nginx` failed the build. There is no list of
registered languages anywhere, and no warning path in `src/highlight.zig` — so
the loop is: guess a language, build for two minutes, fail, guess again.

**Fix.** Any one of: list near-matches in the error; add a `zigapagos languages`
subcommand; or downgrade an unknown language to unhighlighted with a warning.
The last is probably right — a wrong highlight colour is not worth failing a
build over.

---

### DX-13 · [#32] `$link.page("")` is rejected and `$link.site()` is undiscoverable

**What it cost.** A blocked task and a round-trip. `$site.page('')` works in
`.shtml` (the shipped `base.shtml` uses it), so the prose form looks like it
should. `$link.site()` exists and is exactly right, but is found only by reading
`supermd/src/context/utils.zig`.

**Fix.** Name `$link.site()` in the error for an empty page path.

---

### DX-14 · [#33] A dynamic route without a `skeleton` fatals without explaining why

**What happens.** The describe pass rejects it. The reason — SSR substitutes
`"_"` for the parameter, so a component rendering the real value would break
hydration — is sound but not in the message.

**Fix.** Put the reason in the error.

---

### DX-15 · [#34] Generated content has no first-class concept

**What it cost.** Publishing the repository's canonical documentation required
hand-building a generator, a registry file, per-file `.gitignore` entries, and a
freshness test asserting mirrors are deterministic and never committed. That is
a reasonable amount of machinery for "publish these markdown files", and every
project doing it will build it again.

**Fix.** Either a `content_generators` hook in `zigapagos.ziggy`, or — cheaper
and nearly as useful — ship the pattern as a documented recipe with the
generator as a template.

---

## P2 — Documentation gaps

### DX-16 · [#35] Three of the five `client:` directives are undocumented

`docs/islands.md` mentions `client:load` three times and `client:only` once.
`client:idle`, `client:visible` and `client:media` appear **zero** times, though
`src/islands/pass.zig` knows all five. The parser was a more reliable reference
than the documentation, which is the wrong way round.

### DX-17 · [#36] No SuperHTML directive reference, and no list of what does not exist

There is no single page listing `:text`, `:html`, `:loop`, `:if`, `<ctx>`,
`<super>`, `<extend>` and their semantics — and, critically, no statement that
`:attr` does not exist and `:else` does nothing. We attempted `:attr` twice from
different tasks because nothing says it is not a thing.

### DX-18 · [#37] No Scripty builtin reference

`String.eql`, `String.addPath`, `$link.site()`, `$heading.id()`,
`$link.page().ref()` were each discovered by grepping the vendored source. A
generated reference of builtins per type would have removed several hours of
source-reading across this project.

### DX-19 · [#38] `docs/spa.md` has no on-ramp

1,600 lines with no quickstart. The working example at
`examples/tsx-site/app/app.spa.tsx` was consistently more useful than the
specification, and reviewers were told to prefer it when the two disagreed. A
30-line "smallest SPA that works" at the top would change that.

### DX-20 · [#39] No "common build errors" page

A table mapping error message → cause → fix would have short-circuited DX-9,
DX-12, DX-13 and DX-14. These are the messages a new consumer meets in their
first hour.

### DX-21 · [#40] `zigapagos migrate` is described more expansively than it behaves

The tool scans a project and writes a `MIGRATION.md` worklist; `--scaffold`
rewrites island import lines into a separate directory. It converts nothing. We
wrote copy claiming it "applies the mappings" **three separate times** in this
project before catching it, and a fourth instance survived into a page
description — because the surrounding documentation reads as though the tool
does more than it does. Tighten the tool's own help text and the migration
guide's framing so the mistake is harder to make.

---

## P3 — Tooling

### DX-22 · [#41] A `doctor` subcommand

There is no `zigapagos doctor`. Most of the P0 traps are statically detectable
against a built tree: `:if`/`:else` on a real element, a `<Link>` outside a
Router, a layout route with no `<Outlet/>`, a SPA with no `spa.head` stylesheet,
a root-relative `og:*` URL, an alias colliding with a site-wide artifact. One
command that reported those would have caught six of this project's seven worst
defects.

### DX-23 · [#42] Build output does not surface what it emitted

We repeatedly resorted to `find zig-out/site` to learn what a build produced —
and wrote a landing-page section describing a deploy tree that no build actually
emits, because we described the options rather than the output. A `--summary`
flag listing emitted artifacts by category would make that class of error much
harder.

### DX-24 · [#43] `zigapagos version` and release-tag claims drifted from reality

The changelog asserted that inherited release tags existed in this repository
and that `git describe` produced strings derived from them. Neither was true;
both were being published on the documentation site. Worth a test that asserts
the documented version-string shape matches what the binary actually prints.

### DX-25 · [#44] No documented regeneration path for derived binary assets

The social card PNG is rendered from a committed SVG by a tool that is
deliberately not a repository dependency. Edit the SVG and the PNG silently goes
stale. Whatever the convention should be — a comment naming the command, a make
target, a build step — there should be one.

---

## If only three things get done

1. **DX-22 (`doctor`, #41)** — it converts six silent failures into one command.
2. **DX-11 (islands in content, #30)** — it removes the largest structural friction
   in authoring, and would let documentation pages carry live examples.
3. **DX-8 (`$site.page()` on missing targets, #27)** — it removes the single largest
   source of busywork when building a site incrementally.

DX-7 (#26) is the only item a consumer cannot work around, so it belongs on the
roadmap regardless of this list's ordering.

---

# Part II — second wave

Sixteen further findings (#45–#60), filed after the first twenty-five. These are
less about individual traps and more about the shape of the product: the
authoring loop, what CI actually protects, payload, and diagnosability.

## Agent and authoring loop

The stated goal that an agent can complete a migration unattended is worth
taking literally, and these three are what stand between it and that.

- **[#45] DX-26 · A fast `validate` path.** Every verification is a full ~2-minute
  build including island bundling and SSR. The repo's own convention — prove a
  gate fails, then passes — costs two of them. A parse-and-resolve pass with no
  bundling would turn the loop from minutes to seconds, and most of this
  project's failures were detectable in exactly that pass.
- **[#46] DX-27 · Machine-readable diagnostics.** Errors are prose on stderr with
  no codes. An agent parsing `this page has no subpages (page is not a section)`
  is guessing; one switching on a stable code is not.
- **[#47] DX-28 · No `explain <route>`.** We answered "what did this emit, which
  layout rendered it" with `find` and `grep` throughout — and that habit
  produced a defect, a landing section describing a deploy tree no build emits.

## CI and release safety

- **[#48] DX-29 · The marketing site has no PR-time gate.** All four site gates run
  only in `pages.yml` on push to `main`; `ci.yml` covers `examples/tsx-site`
  only. A PR that breaks the site is caught after it merges.
- **[#49] DX-30 · The site's browser smokes are nightly-only.** The only checks
  proving islands hydrate and SPA navigation is genuinely soft — the exact
  defects this project shipped — can sit broken on `main` for a day.
- **[#50] DX-31 · CI pulls an unpinned npm package at runtime** (`bunx serve`), in a
  repository that otherwise pins its toolchain and vendors its dependencies.
- **[#51] DX-32 · No preview deploy.** Every visual judgement here was made by
  reading emitted HTML. That works for assertions and not for "does this read
  well".

## Payload and caching

- **[#52] DX-33 · No island runtime slicing.** A page with one 433-byte Counter
  ships 58,885 bytes, 99.3% of it runtime. Slicing already exists for SPAs
  (`spa/app-runtime.js`, 50,263 B) — islands do not get it. "Zero JS by default"
  is exactly true until a page has one island.
- **[#53] DX-34 · No asset fingerprinting.** Stable asset paths mean a deploy can
  serve stale CSS against fresh HTML, which is what prevents long-lived cache
  headers on output that is otherwise perfectly cacheable.

## Diagnosability

- **[#54] DX-35 · Asset pruning is invisible.** A hand-authored SVG vanished with no
  message when its last reference went away. The behaviour is right; the silence
  is not — and it creates a second-order trap where a `.link()` call must stay
  nested inside another expression purely to hold a refcount.
- **[#55] DX-36 · A directory without `index.smd` yields no subpages, not an error.**
  A missing section presents as "my list is empty" with nothing naming the cause.

## Authoring ergonomics

- **[#56] DX-37 · The recommended first command is one the binary calls deprecated.**
  `zigapagos` with no subcommand is what `init` tells a new user to run, and
  `main.zig` calls it "the deprecated live server". `dev` needs a ZigBase binary,
  so it is not a drop-in.
- **[#57] DX-38 · `init` scaffolds optional frontmatter as required.** `author`,
  `date` and `draft` all have defaults; every template writes them anyway, so
  every consumer copies fields that do nothing. This site's 404 page has an
  author and a publication date.
- **[#58] DX-39 · `client:only` has no placeholder API.** No fallback content for the
  interval before hydration, so the directive demo had to describe the downside
  in prose rather than show a graceful version.
- **[#59] DX-40 · No documented way to test rendered output.** We hand-rolled ~30
  grep assertions and got several wrong in instructive ways — one was green
  before its code existed, one false-positived on prose, one asserted an
  attribute the feature can never emit. Every consumer will repeat this.

## Fork hygiene

- **[#60] DX-41 · The branding gate cannot express a legitimate literal mention.**
  The fork-point tag is *named* with the upstream word, so documentation that
  needs to name that tag cannot pass the gate. We hit this correcting a false
  changelog claim and had to reword around it.

## The through-line

Both waves point the same direction. The product is strong at *doing* the thing
and weak at *telling you what it did* — six of seven top-priority items in the
first wave were silent wrong output, and four of the second wave's themes
(validate, explain, pruning, sections) are the same complaint in different
clothes. A `doctor` command (#41), a `validate` pass (#45), and structured
diagnostics (#46) would between them address most of this list's root cause.
