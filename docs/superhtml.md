> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/superhtml/> — the site is the canonical reading experience.

# SuperHTML directives

Layouts are `.shtml` files in the project's `layouts_dir_path`. They are HTML —
a `.shtml` file with no directives in it is emitted verbatim — plus a small,
**closed** set of template constructs: five `:`-prefixed attributes and three
template-only elements.

Closed is the operative word, and it is why this page exists. There is no
extension point, no `:attr`, no `:else`, no expression interpolation in text
nodes. Anything that looks like a directive and is not on the lists below is
either an ordinary HTML attribute (silently) or a build error (loudly) — the
[These do not exist](#these-do-not-exist) section at the end is the part worth
reading first if you arrived here from a template that did not do what you
expected.

The value of a directive is a Scripty expression — the `$`-prefixed expression
language the whole template layer uses — evaluated against `$page`, `$site`, `$build` and the loop/branch
variables described below.

## The five `:` directives a Zigapagos template may use

| Directive | On | Does |
|-----------|----|------|
| `:text="$expr"` | any element, which must be empty | sets the element's body to `$expr`, HTML-escaped |
| `:html="$expr"` | any element, which must be empty | sets the element's body to `$expr`, **not** escaped |
| `:if="$expr"` | any element with an end tag | keeps or drops the element's **body** |
| `:loop="$expr"` | any element with an end tag | repeats the element's **body** once per item |
| `:props="{ … }"` | `<island>` only | the Ziggy props struct for an island — see the [islands page](islands.md) |

**Two different fives, and they are not the same five.** SuperHTML's own
`SpecialAttr` enum also has exactly five members — `:if`, `:loop`, `:text`,
`:html` and `:else` — and that is the set its parser knows about. The list
above is the set a Zigapagos template may actually *use*, which is that enum
minus `:else` plus `:props`:

- `:else` is in SuperHTML's enum but is parsed and then never evaluated, so
  Zigapagos rejects it at build time — see
  [`:else` does nothing](#else-does-nothing).
- `:props` is not in SuperHTML's enum at all. To SuperHTML it is an ordinary
  attribute; this fork's island pass (`src/islands/pass.zig`) reads it off
  `<island>` elements, which is why it is `<island>`-only and why its value is
  a Ziggy struct rather than a Scripty expression.

`:text` and `:html` are mutually exclusive on one element, and both require the
element to be empty — the directive *is* the body, so existing children would
have nowhere to go. Both are reported by SuperHTML as
`text_and_html_are_mutually_exclusive` and
`text_and_html_require_an_empty_element`.

`:if` and `:loop` are likewise mutually exclusive
(`one_branching_attribute_per_element`): one branching attribute per element.

### `:text` escapes, `:html` does not

Given a page whose `description` is the literal string `<em>raw</em> & text`:

```html
<p :text="$page.description"></p>
<span :html="$page.description"></span>
```

emits

```html
<p>&lt;em&gt;raw&lt;/em&gt; &amp; text</p>
<span><em>raw</em> & text</span>
```

`:text` is the default choice for anything that came from an author. `:html` is
for values that are *already* HTML — `$page.content()`, `$page.toc()`, a
sanitised excerpt — and is a hole in your escaping everywhere else.

`:text` accepts a string or an integer. Anything else, including a bool, fails
the build with `SCRIPT RESULT TYPE MISMATCH` naming the two accepted types — so
`:text="$loop.first"` is an error, not a rendering of `true`.

### `:if` and `:loop` affect the BODY, not the element

This is the single most surprising rule in SuperHTML and the one worth
internalising before writing a layout:

```html
<div class="keepme" :if="$page.title.eql('nope')">HIDDEN-BODY</div>
```

emits, when the condition is false:

```html
<div class="keepme"></div>
```

The tag and every one of its attributes are emitted either way. `:if` decides
whether the *contents* are rendered. The same is true of `:loop` over an empty
sequence: `<ul :loop="$page.subpages()">…</ul>` with no subpages emits
`<ul></ul>`, not nothing.

To make an element *itself* conditional, put the directive on a `<ctx>` wrapper,
which is never emitted:

```html
<ctx :if="$page.title.eql('nope')"><div class="ctx-hidden">CTX-HIDDEN</div></ctx>
```

emits nothing at all when the condition is false.

### `$if`: the unwrapped optional

A Scripty call ending in `?()` returns an optional. `:if` on an optional skips
the body when it is null, and binds the unwrapped value to `$if` when it is not:

```html
<ctx :if="$page.custom.get?('who')">FOUND:<ctx :text="$if"></ctx></ctx>
```

emits `FOUND:ziggy-value` for a page whose frontmatter has
`.custom = { .who = "ziggy-value" }`, and nothing for a page without that key.
`$if` is how the existing layouts reach a page's previous/next sibling
(`<ctx :if="$page.prevPage?()">…<a href="$if.link()">`) without evaluating the
call twice.

Nested `:if`s each rebind `$if` to their own value.

### `$loop`: the iteration variable

Inside a `:loop` body, `$loop` is an iterator with five fields:

| Field | Is |
|-------|-----|
| `$loop.it` | the current item |
| `$loop.idx` | the current index, **1-based** |
| `$loop.len` | the length of the sequence |
| `$loop.first` | true on the first iteration |
| `$loop.last` | true on the last iteration |

and one builtin, `$loop.up()`, which reaches the enclosing `$loop` in a nested
loop (`$loop.up().it`).

```html
<ctx :loop="$site.pages()"><b>[<ctx :text="$loop.idx"></ctx>/<ctx :text="$loop.len"></ctx> <ctx :text="$loop.it.title"></ctx>]</b></ctx>
```

`$loop.idx` starting at 1 rather than 0 is the detail most likely to produce an
off-by-one; `$loop.first` and `$loop.last` exist so you rarely need to compare
it to anything.

A **literal** `id` under a `:loop` is rejected (`id_under_loop`) — the loop would
emit that same id once per iteration, which is invalid HTML. A **scripted** id is
not: `id="$loop.it.slug"` is the idiomatic way to give each iteration its own id,
and it builds. The check also stops at an intervening `:if`, on the grounds that
a branch may already be limiting the element to one iteration (`$loop.first`).

Note what the check can and cannot see: SuperHTML records an element in its
template tree only when the element carries a directive or a scripted attribute,
so a plain `<li id="item">` inside a loop body is not examined at all and emits
duplicate ids with no error. Treat `id_under_loop` as a guard that catches the
common shape, not as a guarantee.

## The three template-only elements

### `<ctx>`

A wrapper that carries a directive and is itself never emitted. Everything above
that needed "make this element conditional" or "repeat exactly this" is a
`<ctx>`.

Every attribute on a `<ctx>` must be a Scripty expression
(`ctx_attrs_must_be_scripted`) — it is a template construct, not an element, so
a literal attribute on one would have nowhere to be emitted to.

### `<extend>` and `<super>`

Template inheritance is id-based and has exactly three moving parts:

1. The child template's **first node** is `<extend template="base.shtml">`
   (`extend_without_template_attr` if the attribute is missing;
   `unexpected_extend` if it is not first).
2. The parent marks each extension point with `<super>` inside an element that
   has an `id` (`super_parent_element_missing_id` otherwise, and
   `top_level_super` if the `<super>` has no such parent). `<super>` takes no
   attributes.
3. The child supplies a **block** — an element with the matching `id` — whose
   content is spliced in at the parent's `<super>`.

This site's own layouts are the worked example. `layouts/templates/base.shtml`
holds the shell:

```html
<head id="head">
  <title :text="$page.title"></title>
  …
  <super>
</head>
<body id="body">
  …
</body>
```

and `layouts/docs.shtml` extends it, filling in just the two blocks it cares
about:

```html
<extend template="base.shtml">
<head id="head">
  <link type="text/css" rel="stylesheet" href="$site.asset('docs.css').link()">
</head>
<main id="main">
  …
</main>
```

Constraints the parser enforces: a block must have an `id`
(`block_missing_id`), two blocks in one template may not share an id
(`duplicate_block`), the parent may not have two `<super>`s under one id
(`two_supers_one_id`), an id may not appear twice in one template's interface
(`template_interface_id_collision`), and a `<super>` may not sit under an `:if`
or a `:loop` (`super_under_branching`).

A template that extends supplies *only* blocks at the top level; a block cannot
be written inline in the middle of other markup (`block_cannot_be_inlined`).

## These do not exist

The rest of this page is the reason it was written. Both of the following were
attempted more than once while building the marketing site, from separate tasks,
because nothing anywhere said they were not real (issue #36).

### `:attr` is not a directive

There is no directive for "set an attribute from an expression", because none is
needed: **an ordinary attribute with a `$` value is already dynamic.**

```html
<a href="$site.asset('logo.svg').link()">     <!-- yes -->
<a :href="$site.asset('logo.svg').link()">    <!-- no -->
```

SuperHTML's `SpecialAttr` enum has exactly five members — `:if`, `:loop`,
`:else`, `:text`, `:html` — and an attribute whose name is not one of them falls
through to normal-attribute handling. So `:href="$expr"` *evaluates* the
expression and then writes it into an attribute literally named `:href`, and the
real `href` is never set. The page renders, the link is dead, and nothing says
so.

Zigapagos lints for this and fails the build (`ZP_TEMPLATE_BAD_DIRECTIVE_ATTR`):

```
layouts/index.shtml:7:4: error: unknown ':' directive attribute ':href'
    SuperHTML's only ':' directives are :if, :loop, :text, :html
    (plus :props on <island>). A dynamic attribute uses the BARE name
    with a Scripty value: write href="$expr", not :href="$expr"
    (the ':' form evaluates the value but keeps the ':href' name, so the
    real 'href' attribute is never set).
```

Every mention of the attribute in that message is the name you actually wrote:
`src/root.zig` formats the offending attribute (and its bare form) into the
text, so the same mistake on `class` reports `:class` throughout. There is no
generic `:attr` wording to grep for.

`zigapagos explain-code ZP_TEMPLATE_BAD_DIRECTIVE_ATTR` prints the long form.

### `:else` does nothing

`:else` is in the enum, and it is validated at parse time — it must be the first
attribute on its element (`else_must_be_first_attr`) and must have no value
(`else_with_value`). Then it is never consulted again: SuperHTML's evaluator has
no case for it. It is not "an else that does not chain", it is not "an else that
works in some positions" — no template using `:else` has ever rendered.

Write the negated condition on a second `<ctx>`:

```html
<ctx :if="$page.draft">Draft</ctx>
<ctx :if="$page.draft.not()">Published</ctx>
```

Zigapagos fails the build on `:else` (`ZP_TEMPLATE_ELSE_DIRECTIVE`) rather than
letting it reach the renderer:

```
layouts/index.shtml:6:10: error: ':else' is parsed but never evaluated
    SuperHTML validates ':else' at parse time and then has no case for
    it at render time: the evaluator reads the attribute's value, which
    a bare ':else' does not have, and panics on the null unwrap. No
    template using ':else' has ever rendered.
    Write the negated condition on a second <ctx> instead:
        <ctx :if="$cond">...</ctx>
        <ctx :if="$cond.not()">...</ctx>
```

That "panics on the null unwrap" is literal: the evaluator reads
`attr.value.?` before it looks at which directive it has, so a bare `:else`
crashes the renderer rather than being ignored. The lint exists to turn that
into a located template error before the output tree is touched.

### `:if` and `:loop` on an element with no end tag

`<img :if="…">`, `<br :loop="…">`, `<input :if="…">` and any self-closing
element cannot work, for two independent reasons: the directive only affects an
element's body and a void element has none, and SuperHTML restarts a conditional
or a loop by rewinding to the element's end tag — with none it rewinds to the
start of the file and re-emits the whole template source into the page with exit
code 0, or slices backwards and panics.

Zigapagos rejects it (`ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG`) and names the
wrapper form:

```
layouts/index.shtml:5:19: error: ':if' on <img> can never work
    <img> is a void element: it has no end tag, and SuperHTML restarts a
    conditional or a loop by rewinding to the element's end tag.
    …
    To make the element itself conditional, wrap it:
        <ctx :if="$cond"><img ...></ctx>
```

### There is no interpolation in text

`<p>Hello {$page.title}</p>` and `<p>Hello $page.title</p>` are both just text.
Scripty is evaluated in *attribute values* only. Text comes from `:text` or
`:html` on an element that has no children.

## Where this is enforced

The three lints above are fork-added, in `src/root.zig`, and each has a
regression fixture under `tests/content-scanning/` —
`bad-directive-attr/`, `else-directive/` and `void-branching-directive/`. Their
codes are in `src/diag-codes.frozen`, so they are stable identifiers a consumer
can match on; the machine-readable shape is described in
[Diagnostics](diagnostics.md).

Everything else on this page is SuperHTML 0.6.2's own behaviour, from the
vendored package in the Zig package cache: the directive set is `Ast.SpecialAttr`
(`src/Ast.zig:68`), the parse-time validation is in the same file's attribute
loop (`:else` at `src/Ast.zig:698`, the mutual-exclusion checks in the
directive switch at `src/Ast.zig:743`), and the render-time dispatch is
`src/template.zig:300` — a `switch` with no `:else` arm, so the directive would
fall through it doing nothing. "Would" because nothing reaches it: `:else` with a
value is rejected at parse time, and a bare one panics on the null unwrap above
before dispatch runs. That tree is a build input and is never edited here —
when a fork-added lint and upstream disagree, the lint is what changes.
