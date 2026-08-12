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

test("slugifyHeading: a double-backtick span is one span, not two empty ones", () => {
  // Issue #66's secondary note. Stripping code markers with `/`([^`]*)`/g`
  // reads a ``-run as an empty span rather than as the delimiter of a span
  // that may contain a literal backtick, so "`` `b` ``" decomposes into two
  // bogus empty spans and leaves the padding spaces behind — one of which
  // survives into the slug as an extra hyphen ("a-and--b"). GitHub renders one
  // span whose content is "`b`" and anchors the heading "a-and-b".
  expect(slugifyHeading("`a` and `` `b` ``")).toBe("a-and-b");
});

test("slugifyHeading: a span containing a literal backtick keeps its content", () => {
  expect(slugifyHeading("Use ``a`b`` here")).toBe("use-ab-here");
});

test("slugifyHeading: an unmatched backtick is not a span", () => {
  // No run of equal length follows, so the backtick is literal text and is
  // dropped by the character class like any other punctuation. Pinned because
  // the span-aware strip must not start swallowing the rest of the heading.
  expect(slugifyHeading("a ` b")).toBe("a--b");
});

test("slugifyHeading: a code span's own underscores survive the emphasis strip", () => {
  // Latent bug hit by issue #152's PR (CI: `unknown ref` on a `.ref(...)`
  // built from this exact slug): the emphasis-stripping regexes used to run
  // on the joined plain string, AFTER code-span delimiters were already
  // gone -- so a code span's own underscore pair read as `_em_` markup and
  // got eaten by `/_([^_]*)_/g`. "Sites with a `url_path_prefix`" slugged to
  // "sites-with-a-urlpathprefix" instead of "sites-with-a-url_path_prefix".
  expect(slugifyHeading("Sites with a `url_path_prefix`")).toBe(
    "sites-with-a-url_path_prefix",
  );
});

test("slugifyHeading: prose emphasis around a code span with underscores is unaffected", () => {
  // The per-segment fix must not stop stripping emphasis in the PROSE
  // segments either -- only a code span's own content is exempt.
  expect(slugifyHeading("_before_ `a_b` _after_")).toBe("before-a_b-after");
});

test("slugifyHeading: underscore emphasis WRAPPING a whole code span is stripped", () => {
  // `` _`a_b`_ `` is `_<code>a_b</code>_` in CommonMark terms -- the whole
  // code span sits inside an underscore-emphasis pair, and the pair must
  // still be recognised and stripped, leaving the span's own underscore.
  // splitCodeSpans puts the two lone underscores in SEPARATE prose segments
  // (one either side of the code segment), so a strip that only ever looks
  // at one segment at a time can never see them as a pair: each one alone
  // fails to match `/_([^_]*)_/g` (there is no second underscore in its own
  // segment) and both survive verbatim into the slug ("_a_b_" instead of
  // "a_b").
  expect(slugifyHeading("_`a_b`_")).toBe("a_b");
});

test("slugifyHeading: star emphasis wrapping a whole code span is stripped", () => {
  expect(slugifyHeading("*`a_b`*")).toBe("a_b");
});

test("slugifyHeading: bold wrapping a whole code span is stripped", () => {
  expect(slugifyHeading("**`a_b`**")).toBe("a_b");
});

test("slugifyHeading: emphasis wrapping a code span, plus surrounding prose", () => {
  expect(slugifyHeading("Before _`x_y`_ After")).toBe("before-x_y-after");
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

test("fence language remap: attributes after the language survive the remap", () => {
  const body = ['```jsonc title="a.json"', '{ "a": 1 }', "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  expect(out.split("\n")[0]).toBe('```json title="a.json"');
});

test("fence language remap: the info string after the language is preserved byte-for-byte", () => {
  // A fence info string is arbitrary text, so its spacing can carry meaning:
  // `title="a  b"` names a file with two spaces in it, and re-joining tokens
  // on a single space silently renames it. Splitting on /\s+/ and re-joining
  // also collapses the run between attributes and drops any spacing between
  // the delimiter and the language, none of which is this transform's to
  // normalise — the remap replaces ONE token and touches nothing else.
  const body = ['```  jsonc  title="a  b"   data-x=1  ', '{ "a": 1 }', "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  expect(out.split("\n")[0]).toBe('```  json  title="a  b"   data-x=1  ');
});

test("fence language remap: a tab-separated info string keeps its tabs", () => {
  // The same defect with a whitespace character that is not a space: re-joining
  // on " " turns an authored tab into a space.
  const body = ["```jsonc\ttitle=x", '{ "a": 1 }', "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  expect(out.split("\n")[0]).toBe("```json\ttitle=x");
});

test("fence language remap: a whitespace-only info string is left alone", () => {
  // Trailing whitespace after a delimiter is not an info string (CommonMark
  // lets a CLOSING fence carry it), so there is no language token to remap and
  // nothing may be rewritten — including the whitespace itself. Reassembling
  // the line from the parsed delimiter, which is what the collapsing version
  // did on its mapped path, would silently eat those three spaces.
  const body = ["```   ", "text", "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { jsonc: "json" } }));
  expect(out.split("\n")[0]).toBe("```   ");
});

test("fence: a nested ``` block inside a ```` block does not desync the tracker", () => {
  // Issue #76. `docs/islands.md` shows fenced Markdown that itself contains a
  // fence; a tracker that toggles on every delimiter-shaped line reads the
  // INNER closer as an opener and stays inverted for the rest of the file —
  // silently, since the only symptom is heading ids and link rewrites going
  // missing. The `.smd` mirror then failed the site build with `unknown ref`
  // on links whose targets had lost their `$heading.id`.
  const body = [
    "````markdown",
    "```=html",
    "<z-island></z-island>",
    "```",
    "````",
    "",
    "## After the block",
    "",
  ].join("\n");
  const out = transformBody(body, opts());
  const lines = out.split("\n");
  // Nothing inside the outer fence was touched...
  expect(lines[1]).toBe("```=html");
  expect(lines[3]).toBe("```");
  // ...and the heading that follows it is back outside the fence.
  expect(out).toContain('## []($heading.id("after-the-block")) After the block');
});

test("fence: a closing run shorter than the opening one does not close it", () => {
  const body = ["````", "```", "## Still fenced", "````", "", "## Real", ""].join("\n");
  const out = transformBody(body, opts());
  expect(out).toContain("## Still fenced");
  expect(out).not.toContain('$heading.id("still-fenced")');
  expect(out).toContain('$heading.id("real")');
});

test("fence: a tilde fence is not closed by a backtick fence", () => {
  const body = ["~~~", "```", "## Still fenced", "~~~", "", "## Real", ""].join("\n");
  const out = transformBody(body, opts());
  expect(out).not.toContain('$heading.id("still-fenced")');
  expect(out).toContain('$heading.id("real")');
});

test("fence: an info string is not restricted to a bare language", () => {
  // SuperMD's raw-HTML escape hatch IS a fence whose info string is `=html`,
  // so an info-string pattern of `[A-Za-z0-9_-]*` fails to see it at all.
  const body = ["```=html", "## Not a heading", "```", "", "## Real", ""].join("\n");
  const out = transformBody(body, opts());
  expect(out).not.toContain('$heading.id("not-a-heading")');
  expect(out).toContain('$heading.id("real")');
});

test("fence: a delimiter-shaped line whose info string holds a backtick is not a fence", () => {
  // CommonMark forbids a backtick in a backtick fence's info string; honouring
  // that is what stops a prose line of inline code from opening a fence and
  // swallowing the rest of the document.
  const body = ["```` `x` is code", "", "## Real", ""].join("\n");
  const out = transformBody(body, opts());
  expect(out).toContain('$heading.id("real")');
});

test("fence language remap: an inherited Object property is a MISS, not a hit", () => {
  // Issue #67. `fenceLangRemap` is an ordinary object literal, so its prototype
  // is `Object.prototype`. A raw `remap[lang]` therefore resolves a fence
  // tagged `constructor` to the `Object` constructor — truthy, so the miss
  // check passes and the whole source text of a function is spliced into the
  // fence's language slot. The build error that follows names the stringified
  // function rather than the fence the author wrote.
  //
  // Every name below is a real `Object.prototype` member and every one of them
  // corrupts the fence under a raw index; `constructor` is only the loudest.
  for (const lang of ["constructor", "toString", "valueOf", "hasOwnProperty", "isPrototypeOf"]) {
    const body = ["```" + lang, "sample", "```", ""].join("\n");
    const out = transformBody(body, opts({ fenceLangRemap: {} }));
    expect(out).toBe(body);
  }
});

test("fence language remap: `__proto__` is a miss too", () => {
  // Separate from the loop above because `__proto__` is an accessor rather than
  // a plain inherited value: `remap["__proto__"]` yields `Object.prototype`
  // itself, which stringifies to "[object Object]".
  const body = ["```__proto__", "sample", "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: {} }));
  expect(out).toBe(body);
});

test("fence language remap: an own property named `constructor` still maps", () => {
  // The guard rejects INHERITED names, not the name itself — a caller that
  // genuinely maps `constructor` must still be honoured.
  const body = ["```constructor", "sample", "```", ""].join("\n");
  const out = transformBody(body, opts({ fenceLangRemap: { constructor: "ts" } }));
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
// inline code spans (issue #66)
//
// The three rows below are the reduced case from the issue body: the same
// link-shaped string, published / unpublished / fenced. Only the third was
// handled before the fix, and neither of the first two failed loudly — one
// published a `$link.page(...)` directive the author never wrote, the other a
// bare GitHub URL with no marker at all. Nothing gates them elsewhere either:
// site/test/docs-mirror.sh's rendered-HTML check strips <pre> and <code>
// before matching, precisely so a page may legitimately document a directive.
// ---------------------------------------------------------------------------

test("code span: a PUBLISHED target inside an inline span is left literal", () => {
  const out = transformBody(
    "A link written as `[text](./spa.md)` is a link.",
    opts({ published: new Map([["docs/spa.md", "docs/spa"]]) }),
  );
  expect(out).toBe("A link written as `[text](./spa.md)` is a link.");
  expect(out).not.toContain("$link.page");
});

test("code span: an UNPUBLISHED target inside an inline span is left literal", () => {
  const seen: string[] = [];
  const out = transformBody(
    "A link written as `[text](./nope.md)` is a link.",
    opts({ onOffsiteLink: (_c, target) => seen.push(target) }),
  );
  expect(out).toBe("A link written as `[text](./nope.md)` is a link.");
  // Not merely unrewritten: the sample must not be reported as a real off-site
  // link either, or a doc that shows link syntax pollutes the offsite report.
  expect(seen).toEqual([]);
});

test("code span: the fenced control from the same case is still untouched", () => {
  const body = ["```", "[text](./spa.md)", "```", ""].join("\n");
  const out = transformBody(
    body,
    opts({ published: new Map([["docs/spa.md", "docs/spa"]]) }),
  );
  expect(out).toBe(body);
});

test("code span: a double-backtick span protects a link-shaped string", () => {
  const out = transformBody(
    "See ``[text](./other.md)`` here.",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe("See ``[text](./other.md)`` here.");
});

test("code span: a span containing a literal backtick closes on a run of exactly N", () => {
  // CommonMark: a span opened with N backticks closes at the next run of
  // EXACTLY N, so the lone backtick in the middle is span content, not a
  // closer. A splitter that closed on the first run of length >= 1 would end
  // the span early and rewrite the link that follows it.
  const out = transformBody(
    "x ``a ` [text](./other.md)`` y",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe("x ``a ` [text](./other.md)`` y");
});

test("code span: a link OUTSIDE a span on the same line is still rewritten", () => {
  // The guard against over-skipping: a line with a span must not stop being
  // link-rewritten wholesale.
  const out = transformBody(
    "See [a](./other.md) and `[b](./other.md)` done.",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe('See [a]($link.page("docs/other")) and `[b](./other.md)` done.');
});

test("code span: an unmatched backtick opens nothing", () => {
  // No later run of equal length, so the backtick is literal text and the rest
  // of the line is ordinary prose — treating it as an opener would silently
  // switch link rewriting off for everything after it.
  const out = transformBody(
    "a ` b [text](./other.md)",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe('a ` b [text]($link.page("docs/other"))');
});

test("code span: a heading's code span is protected, and the heading still gets an id", () => {
  // The heading path runs the link rewrite first and slugifies the result, so
  // both halves have to hold at once: the span survives verbatim AND the id is
  // GitHub's slug for the heading as rendered.
  const out = transformBody(
    "## Writing `[text](./other.md)` links",
    opts({ published: new Map([["docs/other.md", "docs/other"]]) }),
  );
  expect(out).toBe(
    '## []($heading.id("writing-textothermd-links")) Writing `[text](./other.md)` links',
  );
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
