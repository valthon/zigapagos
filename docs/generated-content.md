> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/generated-content/> — the site is the canonical reading experience.

# Generated content

## What this is

Publishing pages that are generated from a canonical source living elsewhere in the
repo — not authored directly as site content. Most of this site's docs pages are built
this way: `docs/*.md`, `docs/migration/*.md` and the root `CHANGELOG.md` are the canonical
files, and a build step mirrors each into a SuperMD page under `site/content/docs/`,
alongside the hand-authored on-ramp pages that have no canonical source elsewhere. This
page is one of the mirrors.

Zigapagos has no built-in `content_generators` config hook. Invoking a script during the
build is the cheap part — a `zig build` pre-step or a `postinstall` script solves that in a
few lines, for any generator. What actually costs is the transformation from ordinary
Markdown into SuperMD: five problems that any canonical-Markdown-to-site-page pipeline
hits, four of which fail the build outright, and none of which a generic "run this script"
hook could do on your behalf, because each depends on what the canonical source actually
contains. So the pattern ships as a recipe to copy, built from the pieces this site already
depends on, rather than as a config field. A hook becomes worth designing once a second
project has run this recipe and found it insufficient — at which point the shape of what it
needs to declare (see the dev-loop caveat at the end) will be known rather than guessed.

## The four-piece pattern

### A registry

[`site/scripts/docs-registry.json`](../site/scripts/docs-registry.json) is a flat list of
canonical path, mirror filename, slug, title and description — one entry per published
page. The generator has no list baked into its own source; adding a page is a data edit to
this file, not a code change. Rendering also reads the curated `title`/`description`
straight out of it, so a page's site-facing framing can differ from its canonical
heading (`docs/spa.md`'s own title is "Native SPA Support"; the registry's curated title
is "Native SPAs").

### A deterministic generator

[`site/scripts/gen-docs-mirror.ts`](../site/scripts/gen-docs-mirror.ts), built on top of
[`site/scripts/md-to-smd.ts`](../site/scripts/md-to-smd.ts) — same input must yield
byte-identical output, because the freshness gate below runs the generator twice and diffs
the two outputs to prove nothing is hand-edited or non-deterministic. A generator that
stamps the output with "now", or that discovers its inputs by walking a directory and takes
them in whatever order the filesystem returned, fails that check by construction — which is
the other reason the inputs come from an explicit registry rather than a glob.

### Per-file `.gitignore` entries

[`site/.gitignore`](../site/.gitignore) lists each mirror path individually rather than
ignoring the whole directory, because authored pages live alongside the mirrored ones —
`site/content/docs/overview.smd` is hand-written and tracked in git, sitting in the same
`content/docs/` directory as the generated mirrors. A blanket `content/docs/*.smd` ignore
would silently hide a real, tracked page from git status and diffs.

### A freshness gate

[`site/test/docs-mirror.sh`](../site/test/docs-mirror.sh) asserts every registry entry
produced a file, the frontmatter is Ziggy, a second generator run changes nothing, no
mirror is accidentally tracked in git, and the built HTML carries no leaked directive.
Without this, an edited-in-place mirror or a stale, un-regenerated commit is invisible
until a reader lands on a page that says the wrong thing.

## The five transformations

Ordinary Markdown is not SuperMD, and the gap is not cosmetic. The first four below are
hard build errors if left undone, not quality-of-life niceties; the fifth is the one that
merely produces a wrong-looking page.

1. **Ziggy frontmatter, not YAML.** SuperMD parses a page's frontmatter block as Ziggy. A
   canonical file that opens with a YAML frontmatter block (the common shape for a doc
   meant to be read on GitHub, or fed into some other static site generator) is a hard
   parse error at build time, not a warning. The mirror gets a Ziggy block synthesized from
   the registry entry instead; the canonical file's own frontmatter, if it has one, is not
   even read.

2. **Relative link targets become link directives, or an absolute URL.** SuperMD does not do
   filesystem-relative link resolution the way GitHub does. Its own link grammar reads a
   leading `.` as "subpage of the current section" — and these doc pages are not sections
   in that sense — so a target written the way GitHub expects:

   ```
   [guards](../spa.md#guards)
   ```

   is not resolved against the filesystem at all once it reaches SuperMD, and the
   unresolved reference fails the build. A target that resolves to a published page becomes
   a `$link.page(...)` directive (with `.ref("anchor")` appended for a `#anchor`); anything
   else degrades to an absolute URL pointing back at the source repository, so a link to a
   file that has no site page still goes somewhere real. This rewrite never touches text
   inside a code sample — neither a fenced block nor an *inline* code span — because a
   link-shaped string in a sample is sample text, not a real link, and rewriting it would
   corrupt the sample. Inline spans follow CommonMark's rule that a span opened with N
   backticks closes on the next run of exactly N, so a sample that itself contains a
   backtick is written by wrapping it in a longer run.

3. **Every heading gets an explicit heading-id directive.** SuperMD does not auto-slugify
   headings into anchors the way GitHub does, so a same-page `#anchor` link — and these
   docs use plenty, written against GitHub's rendering — is an unresolved-reference build
   error unless the target heading carries a matching, explicitly declared id. The
   generator computes that id with the same slug rules GitHub's own heading anchors use, so
   a canonical doc's existing `#anchor` links keep working unmodified. The id has to be
   carried by a leading *empty* link rather than by wrapping the heading's own visible text
   in a link. The reason is a CommonMark limitation, not a style choice: a heading whose
   text already contains square brackets — a changelog's `## [Unreleased]`, say — would, if
   its own text were wrapped in a link, produce a link nested inside a link. CommonMark
   refuses to parse that shape at all, so instead of getting an id, the directive leaks
   into the rendered page as literal, visible text, and the heading is left with no id and
   no working anchor. A leading empty link sidesteps the whole problem, because nothing
   about the heading's own text sits inside it. This is the same pattern upstream's own
   documentation generator uses, for the same reason.

4. **Fence-language remap, mirror-only.** A code-fence language this site's SuperMD
   highlighter doesn't recognize is also a hard build error (`unknown language code`), so a
   handful of real, valid languages that just don't have a grammar registered here — `jsonc`,
   `nginx` — get remapped to a close-enough recognized one (`json`, `conf` respectively) in
   the mirror only. The canonical file keeps its accurate language tag; degrading it to
   satisfy this site's highlighter would trade a worse GitHub-rendering experience for a
   marginally better site-rendering one, which is the wrong direction to make that trade.

5. **The body's own leading title is stripped, mirror-only.** The docs layout renders its
   own top-level heading from the registry's curated `title` field. Leaving a canonical
   file's own `# Title` line in the mirrored body would duplicate that heading and add a
   spurious top-level entry to the page's own table of contents. Only the very first
   top-level heading is eligible, and only when nothing but blank lines precede it — every
   canonical doc opens with exactly that shape once its banner blockquote is stripped, so
   this is "drop the title," not a general heading-removal pass.

Three of those five — the link rewrite, the heading ids and the title strip — are gated on
"is this line inside a fenced code block?", so the fence tracker is load-bearing for all of
them, and it fails in a shape worth knowing about: an inverted tracker produces valid-looking
output with heading ids and link rewrites simply *missing*, and the build error surfaces
pages away, at whichever link pointed at an id that never got written. It therefore follows
CommonMark rather than the common case. A delimiter run is three characters **or more**, so a
doc that demonstrates fenced Markdown by nesting a three-backtick block inside a four-backtick
one does not have the inner closer mistaken for an opener. The info string is arbitrary text,
not just a language word, because SuperMD's own raw-HTML escape hatch *is* a fence whose info
string is `=html`. And a closing fence must use the opener's character, be at least as long,
and carry no info string of its own. Only the first token of an opening fence's info string is
treated as the language for the remap in (4); anything after it is preserved as authored.

What this pattern deliberately does **not** do is sanitize raw HTML. SuperMD rejects raw
HTML in the page body outright (`html_is_forbidden`), so a canonical file that grows an
HTML block fails the site build loudly, at the point the mistake was made. Silently
stripping such a block instead would turn a loud authoring mistake into a quietly
incomplete published page.

## Copy this file

`md-to-smd.ts` is the generic half of the pattern: no repo-specific constant lives in it.
Every repo-specific fact — where the published-page map points, what the fallback URL
prefix is, which fence languages to remap, whether to strip a leading title — is passed in
through one options value:

```ts
export interface TransformOptions {
  canonicalPath: string;
  published: ReadonlyMap<string, string>;
  githubBlobBase: string;
  githubTreeBase: string;
  fenceLangRemap: Readonly<Record<string, string>>;
  stripLeadingTitle: boolean;
  onOffsiteLink?: (canonicalPath: string, target: string, repoPath: string) => void;
}
```

A minimal generator built on it reads: registry entry in, transformed body and Ziggy
frontmatter out.

```ts
import { frontmatter, transformBody } from "./md-to-smd.ts";

const body = transformBody(rawMarkdown, {
  canonicalPath: entry.canonical,
  published: publishedMap,
  githubBlobBase: "https://example.com/blob/main/",
  githubTreeBase: "https://example.com/tree/main/",
  fenceLangRemap: {},
  stripLeadingTitle: true,
});

const page = frontmatter({ title: entry.title, description: entry.description }) + body;
```

`frontmatter` is a minimal Ziggy value emitter, not a general serializer — it handles
strings, numbers, booleans, an unquoted raw expression via `ziggyRaw(...)` (for something
like a `@date(...)` call), and nested objects, which render inline to any depth. It does
not emit arrays; nothing in this pattern needs one, and a project that does should extend
the value type rather than expect one to already exist.

## Copy this gate

`site/test/docs-mirror.sh` is the freshness check, and it is designed to be adapted by
editing the variables at its top rather than its body:

```sh
GENERATOR=scripts/gen-docs-mirror.ts
REGISTRY=scripts/docs-registry.json
MIRROR_DIR=content/docs
BUILD_OUT=zig-out/site
PAGE_PATH_PREFIX=docs
BUILD_CMD=(zig build)
UNIT_TESTS=test/md-to-smd.test.ts
```

Everything below those lines — the missing-file check, the Ziggy-frontmatter check, the
determinism check, the tracked-in-git check, the doubled-opening-bracket regression pin,
and the rendered-HTML directive check — is written against those variables and should not
need to change for a different project's own registry and generator.

The last variable points at [`site/test/md-to-smd.test.ts`](../site/test/md-to-smd.test.ts),
which pins the transformer's sharp edges directly (the GitHub double-hyphen slug rule, the
empty-link heading id, an indented fence, a nested fence, the link-rewrite cases). It is worth copying with
the module: it is the only check that runs on the pure functions rather than on the site
build, so it is the one that tells you *which* transformation broke instead of just that a
page came out wrong. Running it from inside the gate rather than from a separate CI step is
deliberate — one entry point means a project adopting this cannot get a green build by
forgetting to wire the second one up.

## The dev-loop caveat

This is the honest limitation, not a footnote to skip. `zigapagos dev` watches the
layouts, assets, content, data and island directories *under the site root*. A canonical source that lives outside that root — this repository's own `docs/*.md`
and root `CHANGELOG.md` are exactly this case — is not watched, so editing the canonical
file does not trigger a rebuild on its own. The generator has to be re-run by hand (or from
a separate watch process outside the site root) before the dev loop picks up the change.
A built-in `content_generators` hook would have to solve exactly this — watching arbitrary
paths outside the site root and re-invoking a generator on change — to be worth having over
the recipe on this page, and that is real, non-trivial scope that no config value shaped
like "a script to run" would give you for free. That gap is why this ships as a documented
recipe today rather than a config hook.
