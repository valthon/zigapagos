> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/testing/> — the site is the canonical reading experience.

# Testing a built site

Zigapagos builds a directory of files. That is the whole output, and it is the
only place several classes of bug are visible at all — an unprefixed link works
in local preview and 404s in production; an island that failed to server-render
looks identical to one that succeeded until you read the markup.

So the test target is the **built tree**, and the tests are shell scripts that
assert things about it. `site/test/assert.sh` is a sourceable library of the five
assertions that come up every time.

## Using it

```sh
#!/usr/bin/env bash
set -euo pipefail
. site/test/assert.sh

OUT=public
bash build.sh

assert_route_emitted          "$OUT" /docs/islands
assert_element                "$OUT/index.html" link rel=icon
assert_no_script_src          "$OUT/docs/islands/index.html"
assert_internal_links_resolve "$OUT" "$OUT/index.html" /myproj
assert_island_ssr             "$OUT/index.html" components/Counter.island.tsx

echo PASS
```

Each function prints a diagnosis and exits non-zero on failure, so a script that
sources it needs no `|| exit` per line. Portable bash and grep — no bun, no HTML
parser. An assertion library you cannot read in one sitting gets replaced by
greps again.

## The five assertions

### `assert_route_emitted <out-dir> <route>`

The route was emitted **as a page**. Accepts either
`<out>/<route>/index.html` or `<out>/<route>.html`, and requires the file to be
non-empty and to carry a closing `</html>` — so a placeholder stub and a build
killed mid-write both fail. Prints the path it found, so it composes:

```sh
page="$(assert_route_emitted "$OUT" /docs/islands)"
assert_no_script_src "$page"
```

### `assert_element <file> <tag> [attr | attr=value] ...`

An element with this tag and **all** of these attributes exists. Attribute order
does not matter, but every attribute must be in the *same* opening tag. `attr`
alone asserts presence; `attr=value` asserts an exact value.

### `assert_no_script_src <file>`

The page loads no external JavaScript: no `<script>` carries a `src`. Inline
scripts are allowed — a theme-resolution snippet in the head is not a framework,
and banning it would make the assertion unusable on a real site.

### `assert_internal_links_resolve <out-dir> <file> [url-path-prefix]`

Every internal `href`/`src` on the page names a file the build emitted. With a
prefix (a project-pages subpath such as `/myproj`), a root-absolute link that
does *not* carry it fails too — that is the bug that only exists in production.
External, `mailto:`, in-page anchors and relative links are skipped.

The prefix is itself a link: `/myproj`, `/myproj/` and `/myproj#top` are the
three spellings of "home" a project-pages site emits, and all three resolve to
`<out>/index.html`. A fragment or query is removed before the prefix is
checked, so an anchored link is not mistaken for an unprefixed one.

### `assert_island_ssr <file> <island-src>`

The island with this `src` is on the page **and was server-rendered**: its
wrapper is present, it is not `client:only`, its `data-z-props` payload is
present and carries the wrapper's own id, and the wrapper is not empty.

The last two parts are the ones that matter. A wrapper is emitted for every
island including [`client:only`](islands.md#clientonly), which by design ships
no server-rendered markup — so "the island is on the page" and "the island was
server-rendered" are different claims, and only the second means hydration has
something to adopt and a crawler has something to read.

`client:only` is rejected on the **directive**, not on emptiness, because such a
wrapper is not reliably empty. `client:only` is the one directive that may carry
a `<template slot="fallback">` placeholder, and the build writes that markup
inside the wrapper — so an emptiness-only check calls a fallback-carrying island
server-rendered. It is not: the runtime clears the placeholder before mounting,
hydration adopts nothing, and a crawler reads the placeholder.

## Three assertions to avoid

The library is shaped by three mistakes this project made in its own site tests,
because they are the ones a consumer will make too. None of them fails loudly;
all three read in review as coverage.

### An assertion that passed before the code existed

```sh
test -f "$OUT/docs/overview/index.html"     # green for weeks
```

Those four pages were placeholder stubs that already emitted an `index.html`.
The assertion could not distinguish "written" from "will be written", and it was
green throughout.

Every function here hard-fails on a missing **or empty** input rather than
treating absence as nothing-to-check, and `assert_route_emitted` requires the
page to be structurally a page. `site/test/build.sh` now pairs each of those four
with a phrase from its real prose, for the same reason.

### A bare substring that matched prose

```sh
grep -q 'zigapagos-runtime.js' "$OUT/docs/islands/index.html"  # false positive
```

That docs page *documents* the import map, filename and all, inside a code
sample. The substring is in the page; the runtime is not. The assertion was
reporting a JavaScript payload on a genuinely zero-JS page.

`assert_element` matches inside a tag's angle brackets and nowhere else, so page
text can never satisfy it, and `assert_no_script_src` asks the structural
question (does any `<script>` carry a `src`?) rather than looking for a name.

### An assertion for something the feature cannot emit

Asserting an attribute the code has no path to produce is permanently red, and
if it is written alongside a feature that does not exist yet it looks like a
to-do rather than a mistake.

No library can detect this. What these can do is fail *informatively*: a failed
`assert_element` prints the candidate tags it actually found, and a failed
`assert_island_ssr` lists the islands that are on the page. An impossible
assertion then says "found `<div data-z-island …>`, wanted attribute X" on its
first run, rather than a bare "not found" that reads like a missing feature.

## Testing the tests

`site/test/assert.test.sh` runs every assertion against a positive fixture that
must pass and negative fixtures that must fail, plus a missing file and an empty
file for each. The negative fixtures are renderings of the three mistakes above:
a page that mentions the strings in prose, an empty placeholder, and a
`client:only` island.

That self-test is worth copying along with the library. An assertion helper with
no tests of its own is a single point of failure for every test that uses it: a
matcher that silently matches nothing turns a whole suite green.

```sh
bash site/test/assert.test.sh
```

## Where this fits

`site/test/` is this repository's own worked example, and its four gates run in
CI on every pull request:

- `build.sh` — the site builds, and its pages carry what they should.
- `docs-mirror.sh` — the generated docs mirror is complete and deterministic
  (see [Generated content](generated-content.md)).
- `links.sh` — every internal link resolves. This one is the library's first
  consumer: its loop *is* `assert_internal_links_resolve`.
- `js-budget.sh` — the pages that claim to ship no JavaScript still don't.

For behaviour that only exists in a browser — that an island really hydrates,
that an SPA navigation is really soft — a static assertion cannot help, and
`site/test/*_playwright.py` drives a real one instead.

## Snapshot index behavior

`zig build test` compares generated snapshots with the index using
`git diff --exit-code`. New files receive only intent-to-add entries so they are
included in the diff; their contents are never staged, and existing staged
changes are preserved. Review and stage snapshot updates explicitly.

## Schema agreement regression matrix

Run `zig build test-schema` (also exercised by
`tests/schema/structural-agreement.sh` in the batch gate). It compiles the actual
checker against fixture types, then runs twelve matching schemas and 104 incompatible
schema mutations. Matching inputs must exit 0; incompatible inputs must exit 1.
A crash does not count as a rejection. Mutations use temporary schema copies and
never edit the production types or schemas.

The structural inventory below records the checker before the first structural
follow-up. Before this matrix existed, only adding fields to the real Site and Page types had been
manually mutation-checked; the remaining classes had no permanent regression
coverage. All rows now have permanent tests in
`tests/schema/structural_agreement.py`.

| Disagreement | Before the follow-up | Regression coverage now |
| --- | --- | --- |
| Field present on only one side | Rejected in both directions | Remove a required field; add a schema-only field; repeat inside a nested record |
| Skipped Zig field exposed by the schema | Incorrectly accepted | Add the fixture's skipped `hidden` field to the schema |
| Optional versus required | Rejected in both directions for scalar fields and union payloads | Change required/optional scalars and union payloads in both directions; require optional lists, dictionaries and nested records |
| Union case payload present on only one side | A missing schema payload was incorrectly accepted; the reverse was rejected | Remove a payload from a payload-bearing case; add one to a payloadless case |
| Union case present on only one side | Rejected in both directions | Remove a case; add a schema-only case |
| Enum member sets or a schema enum case with a payload | Rejected | Remove/add members; add a payload to a schema member |
| List/dictionary element type or container kind | Rejected for ordinary containers; a slice matched against a named container crashed | Change element scalar/container types; exchange lists, dictionaries, scalars and named containers |
| Optional builtin/custom containers | A valid optional builtin list was rejected, so mutations sharing that baseline could not independently establish coverage | A matching optional-container baseline plus seven independent mutations check builtin/custom list and dictionary elements, requiredness and nested shape |
| Nested struct shape or struct/union/enum kind | Rejected in both directions | Add/remove nested fields, change their types, exchange struct/union/enum kinds and remove a named type |
| Real Page date adapter metadata | The adapter advertised `any`, hiding six mismatches in its union/scalar shape, payload kinds and case set | Mutate the real Page schema; metadata now uses the same tagged-union representation as the existing date parser |
| Real config schema | Fields/scalars rejected; missing `simple` payload accepted | Mutate `Config.Document`'s real schema as well as the fixture schema |
| Scalar kind | Rejected | Exercise all twelve ordered mismatches among `int`, `bool`, `bytes` and `float` |

In that initial 63-negative/four-positive matrix, 46 negative cases already produced ordinary rejections from
the original checker with a valid baseline. Nine exposed false acceptances
(including the real config and date schemas) and one exposed a crash. Seven
further negatives now have an independently valid optional-container baseline.
All four matching schemas pass after the fixes, including the production config
and page schemas. The date parser's accepted spellings and conveniences remain
the same; only its schema metadata is more precise.

The earlier compatibility decisions remain: schemas cannot express required
slices, so required runtime slices are accepted; a non-optional field with a
runtime default may match an optional schema field. Explicit Ziggy custom
`roles` remain authoritative for custom deserializers. The positive baselines
pin the default and required-slice policies alongside the negative cases.

### Complete schema grammar and root coverage

The checker now requires an explicit `types.Document` entry point and starts at
`$ = …`, rather than validating exported type names as independent roots. Every
parsed AST node must be reached by a comparison; every type-expression token
must be consumed. Successful checks cannot leave declarations or expressions
unvisited. The current matrix has 104 negative mutations and twelve positive
baselines, including the reported config roots `$ = bytes` and `$ = Simple`.

| Construct | Handling and regression |
| --- | --- |
| Document root `$ = …` | Compare with `Document` using the same expression walker as fields. Mutate to scalars, optional/list/dictionary wrappers, another struct, a union, an enum, `any`, unknown names, missing/duplicate roots and trailing tokens. Positive non-named roots prove that this is a real comparison. |
| Struct declarations | Compare field sets, nested shape, skipped fields and defaults. A declaration is checked only when reached from the root. Add/remove/change fields and insert an unused nested declaration after its last field. |
| Union declarations | Compare case sets and payload presence/types in both directions, including the real config `simple` case. |
| Enum declarations | Ziggy 0.3 spells enums as payloadless `union` declarations. Compare the exact member set and reject payloads. A literal `enum` declaration is unknown syntax and fails with `schema not checked`. |
| Optional `?` | Compare the optional child, preserving the existing non-optional/default-field compatibility. Optional document roots have no implicit field default. Mutate optional fields, payloads and roots to required forms and vice versa. |
| List `[]` | Compare the builtin slice or declared custom-slice element type recursively. Byte slices are `bytes`, not integer lists. Mutate elements, collection kinds and byte strings; matching optional-list roots pass. |
| Dictionary `{:}` | Compare the declared dictionary element type recursively and keep field-default checks. Matching dictionary roots pass; element/kind mutations fail. |
| `any` | Require explicit unrestricted Dynamic metadata at the leaf. Concrete types cannot match `any`, and Dynamic cannot silently match typed scalar or named leaves. Mutate the actual Page custom field to integer, bytes, bool, float and named leaves. |
| `bytes`, `int`, `float`, `bool` | Compare scalar kinds; `bytes` requires a byte slice. All twelve ordered scalar-kind mismatches and root/string/list mutations reject. |
| Type references | Resolve in the correct lexical scope and recursively compare the referenced declaration. Unknown names reject; a matching declaration elsewhere cannot rescue an incompatible root. |
| Unreferenced declarations | Reject with `schema construct not checked`, including top-level structs, unions, enums and nested declarations. Tests require the coverage-specific diagnostic, not a parsing error. |
| Unknown declarations, invalid or unparsed input | Tokenize the whole file, reject NULs that could hide a suffix, reject parser/reference errors and require complete expression consumption. Mutate unknown declaration syntax, trailing lines and expressions, duplicate roots and hidden declarations. |
| Comments and whitespace | Parsed as grammar trivia; they do not represent additional data constraints. Invalid trivia is a token/parser error, not an ignored line. |

Dynamic's existing wrapping policy is deliberately explicit: dictionary/list
wrappers ending in `any` remain compatible, including nested combinations. Each
wrapper token is consumed and its leaf checked. This permits schema-imposed
container shape for unrestricted Dynamic; it does **not** claim exact wrapper
shape agreement, since Dynamic metadata supplies none. Narrower scalar or named
leaves fail with `schema construct not checked`. Five matching Dynamic root
expressions pin this policy without making the shipped, optional Page custom
field required. Other custom deserializers must supply checked representation
metadata; their implementation fields are not substituted silently.
