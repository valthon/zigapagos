// Generate this site's doc pages from canonical repo markdown.
//
// Mirrors under site/content/docs/ are gitignored build artifacts — edit the
// canonical file (docs/*.md, docs/migration/*.md, or the root CHANGELOG.md),
// never the mirror. This file is this repo's registry + config + loop over
// the generic transformer in scripts/md-to-smd.ts; see docs/generated-content.md
// for the full why of each transformation and for this as a copyable recipe.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { frontmatter, transformBody, ziggyRaw } from "./md-to-smd.ts";

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
// listed alongside the mirrored ones. Values are full site page paths.
const PUBLISHED = new Map<string, string>([
  ...REGISTRY.map((e) => [e.canonical, `docs/${e.slug}`] as [string, string]),
  ["docs/overview.md", "docs/overview"],
  ["docs/quick-start.md", "docs/quick-start"],
  ["docs/tutorial.md", "docs/tutorial"],
  ["docs/configuration.md", "docs/configuration"],
]);

// Mirror-only fence-language remap (transformation 4, see
// docs/generated-content.md). Canonical files keep the accurate tag.
const FENCE_LANG_REMAP: Record<string, string> = {
  jsonc: "json",
  nginx: "conf",
};

/** Strip the canonical-only "also published on the site" banner blockquote.
 * This repo's own banner text, so it stays repo-specific rather than moving
 * into the generic transformer. */
function stripBanner(body: string): string {
  return body.replace(
    /(^|\n)> This documentation is also published[^\n]*(\n>[^\n]*)*\n?/,
    "$1",
  );
}

for (const entry of REGISTRY) {
  const raw = readFileSync(join(REPO_ROOT, entry.canonical), "utf8");
  const body = transformBody(stripBanner(raw), {
    canonicalPath: entry.canonical,
    published: PUBLISHED,
    githubBlobBase: BLOB,
    githubTreeBase: TREE,
    fenceLangRemap: FENCE_LANG_REMAP,
    stripLeadingTitle: true,
    onOffsiteLink: (canonicalPath, target, repoPath) => {
      console.warn(`gen-docs-mirror: [${canonicalPath}] "${target}" → GitHub (${repoPath})`);
    },
  });
  const out =
    frontmatter({
      title: entry.title,
      description: entry.description,
      date: ziggyRaw('@date("2026-07-27T00:00:00")'),
      author: "Zigapagos",
      layout: "docs.shtml",
      draft: false,
      custom: { slug: entry.slug, canonical: entry.canonical },
    }) + body;
  writeFileSync(join(SITE_DIR, "content/docs", entry.mirror), out);
  console.log(`gen-docs-mirror: ${entry.mirror} <- ${entry.canonical}`);
}
