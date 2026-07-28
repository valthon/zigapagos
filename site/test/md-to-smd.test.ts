// Unit tests for the generic markdown->SuperMD transformer. Each test pins a
// real bug that has either been hit before or is one typo away, and every one
// is expected to go red under a single-line mutation of the behaviour it
// names — a test here that survives breaking its own transformation pins
// nothing and should be fixed or deleted.
import { test, expect } from "bun:test";
import { frontmatter, slugifyHeading, transformBody, ziggyRaw } from "../scripts/md-to-smd";
import type { TransformOptions } from "../scripts/md-to-smd";

function opts(overrides: Partial<TransformOptions> = {}): TransformOptions {
  return {
    canonicalPath: "docs/example.md",
    published: new Map(),
    githubBlobBase: "https://example.com/blob/main/",
    githubTreeBase: "https://example.com/tree/main/",
    fenceLangRemap: {},
    stripLeadingTitle: false,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// slugifyHeading
// ---------------------------------------------------------------------------

test("slugifyHeading: em dash between two spaces produces a double hyphen", () => {
  // Whitespace is converted per character, never collapsed: the dash is
  // stripped (it isn't a letter/number/space/hyphen/underscore) but the two
  // flanking spaces both individually become '-'.
  expect(slugifyHeading("Calling the backend — `apiFetch`")).toBe(
    "calling-the-backend--apifetch",
  );
});

test("slugifyHeading: strips inline emphasis and code markers before slugifying", () => {
  expect(slugifyHeading("**Bold** and `code` and _em_ and *star*")).toBe(
    "bold-and-code-and-em-and-star",
  );
});

test("slugifyHeading: does not collapse other multi-space runs either", () => {
  expect(slugifyHeading("a   b")).toBe("a---b");
});

// ---------------------------------------------------------------------------
// heading ids via transformBody
// ---------------------------------------------------------------------------

test("heading id: leading empty link, never wraps the heading's own text", () => {
  const out = transformBody("## [Unreleased]\n", opts());
  // The literal is safe here: site/test/docs-mirror.sh's doubled-bracket
  // regression grep runs over the generated *.smd mirrors, never over test
  // sources, so writing it plainly costs nothing and reads better than
  // assembling it.
  expect(out).not.toContain("[[");
  expect(out).toBe('## []($heading.id("unreleased")) [Unreleased]\n');
});

test("heading id: duplicate heading text dedupes as -1, -2", () => {
  const out = transformBody("## Foo\n## Foo\n## Foo\n", opts());
  const lines = out.split("\n");
  expect(lines[0]).toContain('$heading.id("foo")');
  expect(lines[1]).toContain('$heading.id("foo-1")');
  expect(lines[2]).toContain('$heading.id("foo-2")');
});

// ---------------------------------------------------------------------------
// fences: recognition, indentation, and language remap
// ---------------------------------------------------------------------------

test("fence: an indented fence under a list item is recognised", () => {
  const body = [
    "- a list item",
    "",
    "  ```",
    "  ## Not a real heading",
    "  [text](./other.md)",
    "  ```",
    "",
  ].join("\n");
  // `docs/other.md` IS published, so an un-fenced `./other.md` here would be
  // rewritten to a `$link.page` — the assertions below would catch a fence
  // that stopped being recognised either way, but this makes the rewrite that
  // must not happen a real one rather than a no-op.
  const out = transformBody(
    body,
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  // Untouched: no heading id inserted, no link rewritten.
  expect(out).toContain("  ## Not a real heading");
  expect(out).toContain("  [text](./other.md)");
  expect(out).not.toContain("$heading.id");
  expect(out).not.toContain("$link.page");
});

test("fence language remap: rewrites only the opening delimiter, preserves indent", () => {
  const body = ["  ```jsonc", '  { "a": 1 }', "  ```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  const lines = out.split("\n");
  expect(lines[0]).toBe("  ```json");
  expect(lines[2]).toBe("  ```"); // closing delimiter unchanged, still indented
});

test("fence language remap: an unmapped language is left alone", () => {
  const body = ["```ts", "const x = 1;", "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  expect(out.split("\n")[0]).toBe("```ts");
});

// ---------------------------------------------------------------------------
// link rewriting
// ---------------------------------------------------------------------------

test("link: a published target becomes $link.page", () => {
  const out = transformBody(
    "[text](./other.md)",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe('[text]($link.page("docs/other"))');
});

test("link: a published target with #anchor gains .ref(...)", () => {
  const out = transformBody(
    "[text](./other.md#some-heading)",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe('[text]($link.page("docs/other").ref("some-heading"))');
});

test("link: an unpublished repo path becomes the blob URL and fires onOffsiteLink", () => {
  const seen: Array<[string, string, string]> = [];
  const out = transformBody(
    "[text](./other.md)",
    opts({
      onOffsiteLink: (canonicalPath, target, repoPath) =>
        seen.push([canonicalPath, target, repoPath]),
    }),
  );
  expect(out).toBe('[text](https://example.com/blob/main/docs/other.md)');
  expect(seen).toEqual([["docs/example.md", "./other.md", "docs/other.md"]]);
});

test("link: a trailing-slash target becomes the tree URL, not the blob URL", () => {
  const out = transformBody("[text](./sub/)", opts());
  expect(out).toStartWith("[text](https://example.com/tree/main/");
});

test("link: a bare #anchor is left untouched", () => {
  const out = transformBody("[text](#anchor)", opts());
  expect(out).toBe("[text](#anchor)");
});

test("link: an http(s) URL is left untouched", () => {
  const out = transformBody("[text](https://example.com/x)", opts());
  expect(out).toBe("[text](https://example.com/x)");
});

test("link: a root-absolute path is left untouched", () => {
  const out = transformBody("[text](/absolute/path)", opts());
  expect(out).toBe("[text](/absolute/path)");
});

test("link: an existing $directive is left untouched", () => {
  const out = transformBody('[text]($link.page("docs/x"))', opts());
  expect(out).toBe('[text]($link.page("docs/x"))');
});

test("link: link TEXT is never rewritten, only the target", () => {
  const out = transformBody(
    "[./other.md as text](./other.md)",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe('[./other.md as text]($link.page("docs/other"))');
});

// ---------------------------------------------------------------------------
// stripLeadingTitle
// ---------------------------------------------------------------------------

test("stripLeadingTitle: drops only the first top-level heading, when nothing precedes it but blank lines", () => {
  const body = ["", "", "# Title", "", "Body text.", "", "# Another", ""].join("\n");
  const out = transformBody(body, opts({ stripLeadingTitle: true }));
  // The dropped title got no heading id and no toc entry; the later heading
  // was processed normally, proving it survived rather than being dropped.
  expect(out).not.toContain('$heading.id("title")');
  expect(out).toContain('$heading.id("another")');
});

test("stripLeadingTitle: false leaves the title in place (still gets a heading id, like any other heading)", () => {
  const body = "# Title\n\nBody.\n";
  const out = transformBody(body, opts({ stripLeadingTitle: false }));
  expect(out).toContain('$heading.id("title")');
  expect(out).toContain("Title");
});

test("stripLeadingTitle: real content before the title means nothing is stripped", () => {
  const body = "Not a title.\n\n# Title\n";
  const out = transformBody(body, opts({ stripLeadingTitle: true }));
  expect(out).toContain('$heading.id("title")');
});

// ---------------------------------------------------------------------------
// frontmatter / ziggyRaw
// ---------------------------------------------------------------------------

test("frontmatter: a string containing a double quote is escaped", () => {
  const out = frontmatter({ title: 'Say "hi"' });
  expect(out).toContain('.title = "Say \\"hi\\"",');
});

test("frontmatter: a ziggyRaw value is emitted unquoted", () => {
  const out = frontmatter({ date: ziggyRaw('@date("2026-07-27T00:00:00")') });
  expect(out).toContain('.date = @date("2026-07-27T00:00:00"),');
});

test("frontmatter: a nested object renders inline", () => {
  const out = frontmatter({ custom: { slug: "x", n: 1 } });
  expect(out).toContain('.custom = { .slug = "x", .n = 1 },');
});

test("frontmatter: an empty nested object renders as {}", () => {
  const out = frontmatter({ custom: {} });
  expect(out).toContain(".custom = {},");
});

test("frontmatter: block starts and ends with --- and a trailing blank line", () => {
  const out = frontmatter({ title: "T" });
  const lines = out.split("\n");
  expect(lines[0]).toBe("---");
  expect(lines[lines.length - 2]).toBe("---");
  expect(lines[lines.length - 1]).toBe("");
});
