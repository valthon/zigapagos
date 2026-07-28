// Generate site doc pages from canonical repo markdown.
//
// Mirrors under site/content/docs/ are gitignored build artifacts — edit the
// canonical file (docs/*.md, docs/migration/*.md, or the root CHANGELOG.md),
// never the mirror.
//
// Four transformations are not optional:
//
//   1. Frontmatter must be ZIGGY, not YAML. SuperMD parses frontmatter as
//      Ziggy and a YAML block is a hard error.
//   2. Relative .md links must become Scripty link directives. SuperMD does
//      not do filesystem-relative link resolution the way GitHub does — a
//      bare `](../spa.md)`-shaped target is parsed by SuperMD's own link
//      grammar, where a leading `.` means "subpage of a section" (and these
//      doc pages aren't sections), not "go up a directory". A published
//      target becomes `$link.page('docs/<slug>')` (optionally `.ref(...)`
//      for a `#anchor`); anything else becomes an absolute GitHub URL. This
//      never touches text inside a fenced code block — a link-shaped string
//      in a code sample is sample text, not a real link.
//   3. Every heading needs an explicit `$heading.id(...)`. SuperMD does not
//      auto-slugify headings the way GitHub does, so a same-page `#anchor`
//      link (which these docs use throughout, written against GitHub's
//      rendering) is an `unknown ref` build error unless the target heading
//      carries a matching id. The id is computed with the same slug rules
//      GitHub's own heading anchors use, so the anchor text in the canonical
//      doc does not need to change. The id is carried by a leading EMPTY
//      link — `## []($heading.id("...")) Heading text` — never by wrapping
//      the heading's own text in a link, because a heading like
//      `## [Unreleased]` would then nest a link inside a link, which
//      CommonMark refuses to parse (the directive leaks into the page as
//      literal text and the heading gets no id at all). This is the same
//      pattern upstream's own doc generator uses
//      (zig-pkg/supermd-*/src/docgen.zig), for the same reason.
//   4. A code-fence language SuperMD's highlighter doesn't recognise is a
//      hard build error (`unknown language code`), so `jsonc` and `nginx`
//      fences (real languages, just not ones this fork's highlighter has a
//      grammar for) are remapped to `json`/`conf` — in the MIRROR only. The
//      canonical doc keeps its accurate language tag; degrading that to
//      satisfy this site's highlighter would be publishing a worse GitHub
//      rendering experience in service of a better site one.
//   5. The canonical body's OWN leading `# Title` is dropped, mirror-only.
//      docs.shtml (site/layouts/docs.shtml) renders its own `<h1
//      :text="$page.title">` from the curated registry title ("Native SPAs"
//      rather than the canonical doc's "# Native SPA Support"), so leaving
//      the body's `# Title` in place would both duplicate the h1 and add a
//      spurious top-level entry to `$page.toc()`. Only the FIRST top-level
//      (single `#`) heading is eligible, and only if nothing but blank lines
//      precede it — every canonical doc opens with exactly that shape once
//      the banner blockquote is stripped, so this is "drop the title", not a
//      general heading-stripping pass. Never touches a fenced code block, for
//      the same reason transformation 2/3 don't: a `#`-shaped line inside a
//      code sample is sample text.
//
// What this script deliberately does NOT do is sanitise HTML. SuperMD rejects
// raw HTML with `html_is_forbidden`, so a canonical doc that grows an HTML
// block fails the site build loudly. Silently stripping it would hide an
// authoring mistake and produce a page missing content.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

interface Entry {
  canonical: string;
  mirror: string;
  slug: string;
  title: string;
  description: string;
}

const SITE_DIR = dirname(dirname(fileURLToPath(import.meta.url)));
const REPO_ROOT = dirname(SITE_DIR);
const REGISTRY: Entry[] = JSON.parse(
  readFileSync(join(SITE_DIR, "scripts/docs-registry.json"), "utf8"),
);

const BLOB = "https://github.com/valthon/zigapagos/blob/main/";
const TREE = "https://github.com/valthon/zigapagos/tree/main/";

// Every repo path that has a published site route, so a link to one resolves
// internally instead of bouncing the reader to GitHub. Authored pages are
// listed alongside the mirrored ones.
const PUBLISHED = new Map<string, string>([
  ...REGISTRY.map((e) => [e.canonical, e.slug] as [string, string]),
  ["docs/overview.md", "overview"],
  ["docs/quick-start.md", "quick-start"],
  ["docs/tutorial.md", "tutorial"],
  ["docs/configuration.md", "configuration"],
]);

// Mirror-only fence-language remap (transformation 4 above). Canonical files
// keep the accurate tag.
const FENCE_LANG_REMAP: Record<string, string> = {
  jsonc: "json",
  nginx: "conf",
};

/** Strip the canonical-only "also published on the site" banner blockquote. */
function stripBanner(body: string): string {
  return body.replace(
    /(^|\n)> This documentation is also published[^\n]*(\n>[^\n]*)*\n?/,
    "$1",
  );
}

/** Resolve a relative link target against the canonical file's directory. */
function resolveRepoPath(path: string, canonicalDir: string): string {
  const stack = canonicalDir ? canonicalDir.split("/") : [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    else if (part === "..") stack.pop();
    else stack.push(part);
  }
  return stack.join("/");
}

/**
 * GitHub-compatible heading slug. GitHub (and this codebase's own doc anchors,
 * written against GitHub's rendering) lowercases, strips inline emphasis
 * markers, drops any character that isn't a letter/number/space/hyphen/
 * underscore, and turns each remaining whitespace character into a `-`
 * INDIVIDUALLY — not collapsed. That last part matters: a heading like
 * "Calling the backend — `apiFetch`" has an em dash flanked by two spaces;
 * removing just the dash leaves two spaces, which become two hyphens
 * ("calling-the-backend--apifetch"), matching the double-hyphen anchor the
 * docs already reference.
 */
function slugifyHeading(raw: string): string {
  const plain = raw
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\*\*([^*]*)\*\*/g, "$1")
    .replace(/\*([^*]*)\*/g, "$1")
    .replace(/_([^_]*)_/g, "$1");
  return plain
    .toLowerCase()
    .trim()
    .replace(/[^\p{L}\p{N}\s_-]+/gu, "")
    .replace(/\s/g, "-");
}

/**
 * Rewrite a single non-fenced line's link TARGETS, never link text. A
 * published .md target becomes a `$link.page(...)` Scripty directive
 * (optionally `.ref(...)` for a `#anchor`); any other repo path becomes an
 * absolute GitHub URL, with a warning so an unpublished-but-linked doc is
 * visible rather than quietly degrading into an off-site jump. A bare
 * `#anchor` (same-page) target is left untouched — SuperMD's own
 * `[text](#anchor)` shorthand already handles it, once the target heading
 * carries a matching id.
 */
function rewriteLinksInLine(line: string, canonicalPath: string): string {
  const dir = canonicalPath.includes("/")
    ? canonicalPath.slice(0, canonicalPath.lastIndexOf("/"))
    : "";
  return line.replace(/\]\(([^)\s]+)\)/g, (match, target: string) => {
    const hash = target.indexOf("#");
    const path = hash >= 0 ? target.slice(0, hash) : target;
    const anchor = hash >= 0 ? target.slice(hash + 1) : "";
    if (path === "") return match; // in-page anchor — SuperMD's `#id` shorthand
    if (path.startsWith("$")) return match; // already a Scripty directive
    if (/^(https?:|mailto:)/i.test(path)) return match; // absolute
    if (path.startsWith("/")) return match; // root-absolute, leave as authored

    const repoPath = resolveRepoPath(path, dir);
    const slug = PUBLISHED.get(repoPath);
    if (slug) {
      const refPart = anchor ? `.ref(${JSON.stringify(anchor)})` : "";
      return `]($link.page(${JSON.stringify(`docs/${slug}`)})${refPart})`;
    }

    console.warn(`gen-docs-mirror: [${canonicalPath}] "${path}" → GitHub (${repoPath})`);
    const base = path.endsWith("/") ? TREE : BLOB;
    return `](${base}${repoPath}${anchor ? `#${anchor}` : ""})`;
  });
}

/**
 * Given a non-fenced ATX heading line, return it with a leading empty
 * `$heading.id(...)` link inserted. IDs are deduped per file the same way
 * GitHub dedupes duplicate heading text: repeats get `-1`, `-2`, …
 */
function addHeadingId(line: string, seen: Map<string, number>): string {
  const m = /^(#{1,6})\s+(.+)$/.exec(line);
  if (!m) return line;
  const [, hashes, text] = m;

  let slug = slugifyHeading(text);
  const count = seen.get(slug) ?? 0;
  seen.set(slug, count + 1);
  if (count > 0) slug = `${slug}-${count}`;

  return `${hashes} []($heading.id(${JSON.stringify(slug)})) ${text}`;
}

/**
 * Single line-by-line pass applying transformations 2-5, sharing one fence
 * tracker so link-rewriting, heading-id assignment and the title strip never
 * touch fenced code (a link-shaped or heading-shaped string inside a code
 * sample is sample text), and so the fence-language remap only ever touches
 * a fence's own opening delimiter. The fence delimiter match tolerates
 * leading whitespace — several fences in these docs are indented under a
 * list item.
 *
 * `sawContent` tracks whether anything other than a blank line has been
 * emitted yet; it gates the title strip (transformation 5) to the body's
 * FIRST top-level heading and nothing after it, and is set unconditionally
 * by a fence delimiter so a canonical doc that opens with a code block
 * (none do today, but the check should not depend on that) never has a
 * later `#` line mistaken for the title.
 */
function transformBody(body: string, canonicalPath: string): string {
  const headingIds = new Map<string, number>();
  let inFence = false;
  let strippedTitle = false;
  let sawContent = false;
  const out: string[] = [];

  for (const line of body.split("\n")) {
    const fenceMatch = /^(\s*(?:```|~~~))([A-Za-z0-9_-]*)\s*$/.exec(line);
    if (fenceMatch) {
      const wasInFence = inFence;
      inFence = !inFence;
      sawContent = true;
      if (wasInFence) {
        out.push(line); // closing delimiter, unchanged
      } else {
        const [, prefix, lang] = fenceMatch;
        const mapped = FENCE_LANG_REMAP[lang];
        out.push(mapped ? `${prefix}${mapped}` : line);
      }
      continue;
    }
    if (inFence) {
      out.push(line);
      continue;
    }

    if (!strippedTitle && !sawContent) {
      if (/^#\s+.+$/.test(line)) {
        strippedTitle = true; // drop it: no heading id, no toc entry, no body h1
        continue;
      }
      if (line.trim() === "") {
        out.push(line); // blank line before the title: keep scanning
        continue;
      }
      sawContent = true; // real content and no leading title — nothing to strip
    }

    out.push(addHeadingId(rewriteLinksInLine(line, canonicalPath), headingIds));
  }

  return out.join("\n");
}

/** Ziggy frontmatter. JSON.stringify gives a correctly escaped Ziggy string. */
function frontmatter(e: Entry): string {
  const q = (v: string) => JSON.stringify(v);
  return [
    "---",
    `.title = ${q(e.title)},`,
    `.description = ${q(e.description)},`,
    `.date = @date("2026-07-27T00:00:00"),`,
    `.author = "Zigapagos",`,
    `.layout = "docs.shtml",`,
    `.draft = false,`,
    `.custom = { .slug = ${q(e.slug)}, .canonical = ${q(e.canonical)} },`,
    "---",
    "",
  ].join("\n");
}

for (const entry of REGISTRY) {
  const raw = readFileSync(join(REPO_ROOT, entry.canonical), "utf8");
  const body = transformBody(stripBanner(raw), entry.canonical);
  const out = frontmatter(entry) + body;
  writeFileSync(join(SITE_DIR, "content/docs", entry.mirror), out);
  console.log(`gen-docs-mirror: ${entry.mirror} <- ${entry.canonical}`);
}
