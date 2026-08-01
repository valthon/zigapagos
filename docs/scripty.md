> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/scripty/> — the site is the canonical reading experience.

# Scripty reference

**This page is generated from the source.** Every entry below is read out
of the Zig source with `@typeInfo`, from the `signature`,
`docs_description` and `examples` declarations the builtins already carry
— so a builtin cannot be added, renamed or re-signatured without this page
moving. (Contributors: regenerate with `zig build docs-reference`; do not
hand-edit `docs/scripty.md`. `tests/meta/scripty-reference.sh` fails the
build when the committed copy and a fresh generation disagree.)

Scripty is the expression language in `$`-prefixed values. It appears in two
places, and they have different vocabularies:

- **In a `.shtml` layout**, inside a directive or an attribute value —
  `<h1 :text="$page.title">`, `<a href="$site.asset('logo.svg').link()">`.
  That vocabulary is the [global scope](#global-scope) and the
  [types](#types) below.
- **In a `.smd` content file**, inside a link target —
  `[home]($link.site())`, `## []($heading.id("intro")) Intro`. That
  vocabulary is the [content directives](#content-directives), which are a
  different set entirely.

A function marked `?` (`get?`, `prevPage?`) returns an optional instead of
erroring, which is what `:if` unwraps into `$if`. In Scripty every error is
unrecoverable and fails the build.

## Global scope

The names available at the start of any `.shtml` Scripty expression.

### `$site` : Site

The current website. In a multilingual website,
each locale will have its own separate instance of `$site`

### `$page` : Page

The page being currently rendered.

### `$build` : Build

Gives you access to build-time assets (i.e. assets built
 via the Zig build system) alongside other information
relative to the current build.

### `$i18n` : Map

In a multilingual website it contains the translations 
defined in the corresponding i18n file.

See the i18n docs for more info.

### `$ctx` : Ctx

A key-value mapping that contains data defined in `<ctx>`
nodes.

### `$loop` : ?Iterator

The current iterator, only available within elements
that have a `loop` attribute.

### `$if` : ?Optional

The current branching variable, only available within elements
that have an `if` attribute used to unwrap an optional value.

## Types

Every type a `.shtml` Scripty expression can evaluate to, with its data
fields and its functions.

### Root



Fields:

- `site` : Site — The current website. In a multilingual website, each locale will have its own separate instance of `$site`
- `page` : Page — The page being currently rendered.
- `build` : Build — Gives you access to build-time assets (i.e. assets built via the Zig build system) alongside other information relative to the current build.
- `i18n` : Map — In a multilingual website it contains the translations defined in the corresponding i18n file. See the i18n docs for more info.
- `ctx` : Ctx — A key-value mapping that contains data defined in `<ctx>` nodes.
- `loop` : ?Iterator — The current iterator, only available within elements that have a `loop` attribute.
- `if` : ?Optional — The current branching variable, only available within elements that have an `if` attribute used to unwrap an optional value.

### Site

The global site configuration. The fields come from your 
`zigapagos.ziggy`.
 
 Gives you also access to assets and static assets from the directories 
 defined in your site configuration.

Fields:

- `host_url` : String — The host URL, as defined in your `zigapagos.ziggy`.
- `title` : String — The website title, as defined in your `zigapagos.ziggy`.

#### `Site.localeCode() -> String`

In a multilingual website, returns the locale of the current 
variant as defined in your `zigapagos.ziggy`. 

```superhtml
<html lang="$site.localeCode()"></html>
```

#### `Site.localeName() -> String`

In a multilingual website, returns the locale name of the current 
variant as defined in your `zigapagos.ziggy`. 

```superhtml
<span :text="$site.localeName()"></span>
```

#### `Site.link() -> String`

Returns a link to the homepage of the website.

Correctly links to a subpath when correct to do so in a  
multilingual website.

```superhtml
<a href="$site.link()" :text="$site.title"></a>
```

#### `Site.asset(String) -> Asset`

Retuns an asset by name from inside the assets directory.

```superhtml
<img src="$site.asset('foo.png').link()">
```

#### `Site.data(String) -> Map`

Returns a site-wide global data file as a Ziggy map.

The argument is the basename (without extension) of a `.ziggy`
file in the site's `data_dir_path` (default `data/`), parsed once
at build time. This is the Zigapagos equivalent of Astro's shared
"content database" singleton (e.g. a `main.json` read by every
page via `getSite()`): one source of truth, many consumers — read
the same data from any layout instead of duplicating it into each
page's frontmatter.

Index into the returned map with `.get('field')`, chaining for
nested maps.

```superhtml
<span :text="$site.data('site').get('owner').get('name')"></span>
```

#### `Site.page(String) -> Page`

Finds a page by path.

Paths are relative to the content directory and should exclude
the markdown suffix as Zigapagos will automatically infer which file
naming convention is used by the target page.

For example, the value 'foo/bar' will be automatically
matched by Zigapagos with either:
 - content/foo/bar.smd
 - content/foo/bar/index.smd

To reference the site homepage, pass an empty string.

```superhtml
<a href="$site.page('downloads').link()">Downloads</a>
```

#### `Site.pages([String...]) -> [Page]`

Same as `page`, but accepts a variable number of page references and 
loops over them in the provided order. All pages must exist.

Calling this function with no arguments will loop over all pages
of the site.

To be used in conjunction with a `loop` attribute.

```superhtml
<ul :loop="$site.pages('a', 'b', 'c')"><li :text="$loop.it.title"></li></ul>
<ul :loop="$site.pages()"><li :text="$loop.it.title"></li></ul>
```

#### `Site.locale(String) -> Site`

Returns the Site corresponding to the provided locale code.

Only available in multilingual websites.

```superhtml
<a href="$site.locale('en-US').link()">Murica</a>
```

### Page

The page currently being rendered.

Fields:

- `title` : String — Title of the page, as set in the SuperMD frontmatter.
- `description` : String — Description of the page, as set in the SuperMD frontmatter.
- `author` : String — Author of the page, as set in the SuperMD frontmatter.
- `date` : DateTime — Publication date of the page, as set in the SuperMD frontmatter. Used to provide default ordering of pages.
- `layout` : String — SuperHTML layout used to render the page, as set in the SuperMD frontmatter.
- `draft` : Bool — When set to true the page will not be rendered in release mode, as set in the SuperMD frontmatter.
- `tags` : [String] — Tags associated with the page, as set in the SuperMD frontmatter.
- `aliases` : [String] — Aliases of the current page, as set in the SuperMD frontmatter. Aliases can be used to make the same page available from different locations. Every entry in the list is an output location where the rendered page will be copied to. Entries are joined to the page's output directory; start an entry with `/` to place it relative to the site root (e.g. `"/404.html"` to override the site-wide 404 page).
- `alternatives` : [Alternative] — Alternative versions of the page, as set in the SuperMD frontmatter. Alternatives are a good way of implementing RSS feeds, for example.
- `skip_subdirs` : Bool — Skips any other potential content present in the subdir of the page, as set in the SuperMD frontmatter. Can only be set to true on section pages (i.e. `index.smd` pages).
- `translation_key` : ?String — Translation key used to map this page with corresponding localized variants, as set in the SuperMD frontmatter. See the docs on i18n for more info.
- `custom` : Value — A Ziggy map where you can define custom properties for the page, as set in the SuperMD frontmatter.

#### `Page.isCurrent() -> Bool`

Returns true if the target page is the one currently being 
rendered. 

To be used in conjunction with the various functions that give 
you references to other pages, like `$site.page()`, for example.

```superhtml
<div class="$site.page('foo').isCurrent().then('selected')"></div>
```

#### `Page.asset(String) -> Asset`

Retuns an asset by name from inside the page's asset directory.

Assets for a non-section page must be placed under a subdirectory 
that shares the same name with the corresponding markdown file.

(as a reminder sections are defined by pages named `index.smd`)

| section? |     page path      | asset directory |
|----------|--------------------|-----------------|
|   yes    | blog/foo/index.smd |    blog/foo/    |
|   no     | blog/bar.smd       |    blog/bar/    |

```superhtml
<img src="$page.asset('foo.png').link(false)">
```

#### `Page.site() -> Site`

Returns the Site that the page belongs to.

```superhtml
<div :text="$page.site().localeName()"></div>
```

#### `Page.locale(String) -> ?Page`

Returns a reference to a localized variant of the target page.


```superhtml
<div :text="$page.locale('en-US').title"></div>
```

#### `Page.locale?(String) -> ?Page`

Returns a reference to a localized variant of the target page, if
present. Returns null otherwise.

To be used in conjunction with an `if` attribute.

```superhtml
<div :if="$page.locale?('en-US')">
  <a href="$if.link()" :text="$if.title"></a>
</div>
```

#### `Page.locales() -> [Page]`

Returns the list of localized variants of the current page.

```superhtml
<div :loop="$page.locales()"><a href="$loop.it.link()" :text="$loop.it.title"></a></div>
```

#### `Page.wordCount() -> Int`

Returns the word count of the page.

The count is performed assuming 5-letter words, so it actually
counts all characters and divides the result by 5.

```superhtml
<div :loop="$page.wordCount()"></div>
```

#### `Page.parentSection() -> Page`

Returns the parent section of a page. 

It's always an error to call this function on the site's main 
index page as it doesn't have a parent section.

```superhtml
$page.parentSection()
```

#### `Page.isSection() -> Bool`

Returns true if the current page defines a section (i.e. if 
the current page is an 'index.smd' page).


```superhtml
$page.isSection()
```

#### `Page.subpages() -> [Page]`

Returns a list of all the pages in this section. If the page is 
not a section, returns an empty list.

Sections are defined by `index.smd` files, see the content 
structure section in the official docs for more info.

```superhtml
<div :loop="$page.subpages()">
  <span :text="$loop.it.title"></span>
</div>
```

#### `Page.subpagesAlphabetic() -> [Page]`

Same as `subpages`, but returns the pages in alphabetic order by
comparing their titles. 

```superhtml
<div :loop="$page.subpagesAlphabetic()">
  <span :text="$loop.it.title"></span>
</div>
```

#### `Page.nextPage?() -> ?Page`

Returns the next page in the same section, sorted by date. 

The returned value is an optional to be used in conjunction 
with an `if` attribute. Use `$if` to access the unpacked value
within the `if` block.

```superhtml
<div :if="$page.nextPage?()">
  <span :text="$if.title"></span>
</div>
```

#### `Page.prevPage?() -> ?Page`

Tries to return the page before the target one (sorted by date), to be used with an `if` attribute.

```superhtml
<div :if="$page.prevPage?()"></div>
```

#### `Page.hasNext() -> Bool`

Returns true of the target page has another page after (sorted by date) 

```superhtml
$page.hasNext()
```

#### `Page.hasPrev() -> Bool`

Returns true of the target page has another page before (sorted by date) 

```superhtml
$page.hasPrev()
```

#### `Page.link() -> String`

Returns the URL of the target page.

In multilingual sites, if the target page belongs to a different
localized variant, the link will containt the full host URL if
'host_url_override' was specified for either page.

```superhtml
$page.link()
```

#### `Page.linkRef(String) -> String`

Returns the URL of the target page, allowing you 
to specify a fragment id to deep-link to a specific
element of the content page.

The id will be checked by Zigapagos and an error will be
reported if it does not exist.

See the SuperMD reference documentation to learn how to give
ids to elements.

```superhtml
$page.linkRef('foo')
```

#### `Page.alternative(String) -> Alternative`

Returns an alternative by name.

```superhtml
<ctx alt="$page.alternative('rss')">
  <a href="$ctx.alt.link()" 
     type="$ctx.alt.type" 
     :text="$ctx.alt.name"
  ></a>
```

#### `Page.content() -> String`

Renders the full Markdown page to HTML

```superhtml

```

#### `Page.contentSection(String) -> String`

Renders the specified \[content section]\(`$link.page('docs/supermd/scripty').ref('Section')`) of a page.

```superhtml
<div :html="$page.contentSection('section-id')"></div>
<div :html="$page.contentSection('other-section')"></div>
```

#### `Page.hasContentSection(String) -> Bool`

Returns true if the page contains a content-section with the given id

```superhtml
<div :if="$page.hasContentSection('section-id')">
  <div :html="$page.contentSection('section-id')"></div>
</div>
```

#### `Page.contentSections() -> [ContentSection]`

Returns a list of sections for the current page.

A page that doesn't define any section will have
a default section for the whole document with a 
null id.

```superhtml
<div :html="$page.contentSections()"></div>
```

#### `Page.footnotes?() -> ?[Footnote]`

Returns a list of footnotes for the current page, if any exist.

```superhtml
<ctx :if="$page.footnotes?()">
  <ol :loop="$if">
    <li id="$loop.it.def_id">
      <ctx :html="$loop.it.html()"></ctx>
      <ctx :loop="$loop.it.ref_ids">
        <a href="$loop.it.prefix('#')" :html="$loop.idx"></a>
      </ctx>
    </li>
  </ol>
</ctx>
```

#### `Page.toc() -> String`

Renders the table of content.

```superhtml
<div :html="$page.toc()"></div>
```

### MissingPage

A page reference that doesn't resolve to an existing page, returned by
`$site.page(...)` only when the site is built with `--allow-missing-pages`
(an ordinary lookup miss is a hard build error otherwise -- this type
exists so an "under construction" nav link doesn't have to block every
other page from building).

A missing page has no title, no content, nothing else that could be
honestly returned -- so the only available operation is `.link()`, which
returns the URL the page WILL have once it's written. That URL is a 404
until then; that is what "missing" means.

#### `MissingPage.link() -> String`

Returns the URL the missing page will have once it exists.

```superhtml
$site.page('coming-soon').link()
```

### Ctx

A special map that contains all the attributes
 defined on `<ctx>` in the current scope.

You can access the available fields using dot notation.

Example:
```superhtml
<div>
  <ctx foo="(scripty expr)" bar="(scripty expr)"> 
    <span :text="$ctx.foo"></span>
    <span :text="$ctx.bar"></span>
  </ctx>
</div>
```

### Alternative

An alternative version of the current page. Title and type
can be used when generating `<link rel="alternate">` elements.

Fields:

- `name` : String — A name that can be used to fetch this alternative version of the page.
- `layout` : String — The SuperHTML layout to use to generate this alternative version of the page.
- `output` : String — Output path where to to put the generated alternative.
- `type` : String — A metadata field that can be used to set the content-type of this alternative version of the Page. Useful for example to generate RSS links: ```superhtml <ctx alt="`$page.alternative('rss')`"> <a href="`$ctx.alt.link()`" type="`$ctx.alt.type`" :text="`$ctx.alt.name`" ></a> </ctx> ```

#### `Alternative.link() -> String`

Returns the URL of the target alternative.

```superhtml
$page.alternative("rss").link()
```

### ContentSection

A content section from a page.

Fields:

- `id` : String — The id of the current section.
- `data` : Map — A Ziggy Map that contains data key-value pairs set in SuperMD

#### `ContentSection.heading() -> String`

If the section starts with a heading element,
this function returns the heading as simple text.           

```superhtml
<div :html="$loop.it.heading()"></div>
```

#### `ContentSection.heading?() -> ?String`

If the section starts with a heading element,
this function returns the heading as simple text.           

```superhtml
<ctx :if="$loop.it.heading?()"><span :text="$if"></span></ctx>
```

#### `ContentSection.html() -> String`

Renders the section.

```superhtml
<div :html="$loop.it.html()"></div>
```

#### `ContentSection.htmlNoHeading() -> String`

Renders the section but omits the section heading if present.

```superhtml
<div :html="$loop.it.htmlNoHeading()"></div>
```

### Footnote

A footnote from a page.

Fields:

- `def_id` : String — The ID for the footnote definition.
- `ref_ids` : [String] — The IDs of the footnote's references, to be used for creating backlinks.

#### `Footnote.html() -> String`

Renders the footnote definition.

```superhtml

```

### Build

Gives you access to build-time assets and other build related info.
When inside of a git repository it also gives git-related metadata.

Fields:

- `generated` : DateTime — Returns the current date when the build is taking place. ># \[Note]\(`$block.attrs('note')`) >Using this function will not add a dependency on the current time >for the page, hence the name `generated`. > >To get the best results, use in conjunction with caching as otherwise >the page will be regenerated anew every single time.

#### `Build.asset(String) -> Asset`

Returns a build-time asset (one declared with `--build-asset=NAME PATH`) by name.

```superhtml
<div :text="$build.asset('foo').bytes()"></div>
```

#### `Build.git() -> Git`

Returns git-related metadata if you are inside a git repository.
If you are not or the parsing failes, it will return an error.
Packed object are not supported, commit anything to get the metadata.

```superhtml
<div :text="$build.git()..."></div>
```

#### `Build.git?() -> Git`

Returns git-related metadata if you are inside a git repository.
If you are not or the parsing failes, it will return null.
Packed object are not supported, commit anything to get the metadata.

```superhtml
<div :if="$build.git?()">...</div>
```

### Git

Information about the current git repository.

Fields:

- `commit_hash` : String — The current commit hash.
- `commit_date` : DateTime — The date of the current commit.
- `commit_message` : String — The commit message of the current commit.
- `author_name` : String — The name of the author of the current commit.
- `author_email` : String — The email of the author of the current commit.

#### `Git.tag() -> String`

Returns the tag of the current commit.
If the current commit does not have a tag, an error is returned.

```superhtml
<div :text="$build.git().tag()"></div>
<div :if="$build.git?()"><span :text="$if.tag()"></span></div>
```

#### `Git.tag?() -> String`

Returns the tag of the current commit.
If the current commit does not have a tag, null is returned.

```superhtml
<div :if="$build.git().tag?()"><span :text="$if"></span></div>
<div :if="$build.git?()"><span :if="$if.tag?()"><span :text="$if"></span></span></div>
```

#### `Git.branch() -> String`

Returns the branch of the current commit.
If the current commit does not have a branch, an error is returned.

```superhtml
<div :text="$build.git().branch()"></div>
<div :if="$build.git?()"><span :text="$if.branch()"></span></div>
```

#### `Git.branch?() -> String`

Returns the branch of the current commit.
If the current commit does not have a branch, null is returned.

```superhtml
<div :if="$build.git().branch?()"><span :text="$if"></span></div>
<div :if="$build.git?()"><span :if="$if.branch?()"><span :text="$if"></span></span></div>
```

### Asset

Represents an asset.

#### `Asset.link() -> String`

Returns a link to the asset.

Calling `link` on an asset will cause it to be installed
under the same relative path into the output directory.

    `content/post/bar.jpg` -> `public/post/bar.jpg`
  `assets/foo/bar/baz.jpg` -> `public/foo/bar/baz.jpg`

Build assets will be installed under the path their
`--install`/`--install-always` names.

The result is root-relative. Use `absLink()` instead for a
URL that is consumed outside the page and therefore has to
be absolute: social metadata, canonical links, feeds.

```superhtml
<img src="$site.asset('logo.jpg').link()">
<img src="$page.asset('profile.jpg').link()">
```

#### `Asset.absLink() -> String`

Like `link()`, but always returns an absolute URL
(host_url + url_path_prefix + asset path). Calling it
installs the asset, exactly like `link()`.

Required for URLs consumed outside the page: `og:*` and
`twitter:*` meta tags, canonical links, feeds. Scrapers do
not resolve root-relative URLs.

```superhtml
<meta property="og:image" content="$site.asset('og.png').absLink()">
```

#### `Asset.size() -> String`

Returns the size of an asset file in bytes.

```superhtml
<div :text="$site.asset('foo.json').size()"></div>
```

#### `Asset.bytes() -> String`

Returns the raw contents of an asset.

```superhtml
<div :text="$page.assets.file('foo.json').bytes()"></div>
```

#### `Asset.sriHash() -> String`

Returns the Base64-encoded SHA384 hash of an asset, prefixed with `sha384-`, for use with Subresource Integrity.

```superhtml
<script src="$site.asset('foo.js').link()" integrity="$site.asset('foo.js').sriHash()"></script>
```

#### `Asset.ziggy() -> any`

Tries to parse the asset as a Ziggy document.

```superhtml
<div :text="$page.assets.file('foo.ziggy').ziggy().get('bar')"></div>
```

### Map

A map that can hold any value, used to represent the `custom` field 
in Page frontmatters or Ziggy / JSON data loaded from assets.

#### `Map.toJson() -> String`

Serializes the map to a JSON string.

Use it to pass structured data into a typed island prop:
`prop-NAME="$page.custom.get('cfg').toJson()"` (or with
`$site.data(...)`). The island's `Props` field is then parsed from
that JSON, so a map/struct field receives the whole shape — the
dynamic-attribute analogue of an inline `:props='{ ... }'` literal.

```superhtml
<island src="C.zig" prop-cfg="$page.custom.get('cfg').toJson()"></island>
```

#### `Map.getOr(String, String) -> String`

Tries to get a value from a map, returns the second value on failure.


```superhtml
$page.custom.getOr('coauthor', 'Loris Cro')
```

#### `Map.get(String) -> any`

Tries to get a value from a map, errors out if the value is not present.


```superhtml
$page.custom.get('coauthor')
```

#### `Map.get?(String) -> ?any`

Tries to get a dynamic value, to be used in conjuction with an `if` attribute.


```superhtml
<div :if="$page.custom.get?('myValue')">
  <span :text="$if"></span>
</div>
```

#### `Map.has(String) -> Bool`

Returns true if the map contains the provided key.


```superhtml
<div :if="$page.custom.has('myValue')">Yep!</div>
```

#### `Map.iterate() -> [KV]`

Iterates over key-value pairs of a Ziggy map.

```superhtml
$page.custom.iterate()
```

#### `Map.iterPattern(String) -> [KV]`

Iterates over key-value pairs of a Ziggy map where the key
matches the given pattern.

```superhtml
$page.custom.iterPattern("user-")
```

### Optional

An optional value, to be used in conjunction with `if` attributes.

### String

A string.

#### `String.len() -> Int`

Returns the length of a string.


```superhtml
$page.title.len()
```

#### `String.contains(String) -> Bool`

Returns true if the receiver contains the provided string.


```superhtml
$page.permalink().contains("/blog/")
```

#### `String.endsWith(String) -> Bool`

Returns true if the receiver ends with the provided string.


```superhtml
$page.permalink().endsWith("/blog/")
```

#### `String.startsWith(String) -> Bool`

Returns true if the receiver starts with the provided string.


```superhtml
$page.permalink().startsWith("/blog/")
```

#### `String.eql(String) -> Bool`

Returns true if the receiver equals the provided string.


```superhtml
$page.author.eql("Loris Cro")
```

#### `String.basename() -> String`

Returns the last component of a path.

```superhtml
TODO
```

#### `String.suffix(String, [String...]) -> String`

Concatenates strings together (left-to-right).


```superhtml
$page.title.suffix("Foo","Bar", "Baz")
```

#### `String.prefix(String, [String...]) -> String`

Concatenates strings together (left-to-right) and
prepends them to the receiver string.

```superhtml
$page.title.prefix("Foo","Bar", "Baz")
```

#### `String.fmt(String, [String...]) -> String`

Looks for '{}' placeholders in the receiver string and 
replaces them with the provided arguments.


```superhtml
$i18n.get!("welcome-message").fmt($page.custom.get!("name"))
```

#### `String.addPath(String, [String...]) -> String`

Joins URL path segments automatically adding `/` as needed. 

```superhtml
$site.host_url.addPath("rss.xml")
$site.host_url.addPath("foo/bar", "/baz")
```

#### `String.syntaxHighlight(String) -> String`

Applies syntax highlighting to a string.
The argument specifies the language name.


```superhtml
<pre>
  <code class="ziggy" 
        :html="$page.custom.get('sample').syntaxHighlight('ziggy')"
  ></code>
</pre>
```

#### `String.parseInt() -> Int`

Parses an integer out of a string


```superhtml
$page.custom.get!('not-a-num-for-some-reason').parseInt()
```

#### `String.parseDate() -> Date`

Parses a Date out of a string.

```superhtml
$page.custom.get('foo').parseDate()
```

#### `String.splitN(String, Int) -> String`

Splits the string using the first string argument as delimiter and then
returns the Nth substring (where N is the second argument).

Indices start from 0.


```superhtml
$page.author.splitN(" ", 1)
```

#### `String.lower() -> String`

Returns a lowercase version of the target string.


```superhtml
$page.title.lower()
```

### DateTime

A datetime.

#### `DateTime.gt(Date) -> Bool`

Return true if lhs is later than rhs (the argument).


```superhtml
$page.date.gt($page.custom.expiry_date)
```

#### `DateTime.lt(Date) -> Bool`

Return true if lhs is earlier than rhs (the argument).


```superhtml
$page.date.lt($page.custom.expiry_date)
```

#### `DateTime.eq(Date) -> Bool`

Return true if lhs is the same instant as the rhs (the argument).


```superhtml
$page.date.eq($page.custom.expiry_date)
```

#### `DateTime.in(String) -> Date`

Change the Time Zone offset of a date with the offset
of the location provided.

```superhtml
$page.date.in("Europe/Berlin")
```

#### `DateTime.add(Int, String) -> Date`

 Add a given duration to the receiver date.
 A duration is specified as a number of units, with possible units being:
 - 'second'
 - 'minute'
 - 'hour'
 - 'day'

```superhtml
$page.date.add(1, 'day').add(1, 'hour')
```

#### `DateTime.sub(Int, String) -> Date`

 Subtract a given duration to the receiver date.
 A duration is specified as a number of units, with possible units being:
 - 'second'
 - 'minute'
 - 'hour'
 - 'day'

```superhtml
$page.date.sub(1, 'hour').add(1, 'hour').eq($page.date)
```

#### `DateTime.format(String) -> String`

Formats a datetime according to the specified format string.

Zigapagos uses Go-style format strings, which are all variations based
on a "magic date":

- `Mon Jan 2 15:04:05 MST 2006`

By tweaking its components you can specify various formatting styles.

```superhtml
$page.date.format("January 02, 2006")
$page.date.format("06-Jan-02")
$page.date.format("2006/01/02")
$page.date.format("2006/01/02 15:04 MST")
```

#### `DateTime.formatHTTP() -> String`

Formats a datetime according to the HTTP spec.


```superhtml
$page.date.formatHTTP()
```

### Bool

A boolean value

#### `Bool.then(String, ?String) -> String`

If the boolean is `true`, returns the first argument.
Otherwise, returns the second argument.

The second argument defaults to an empty string.


```superhtml
$page.draft.then("<alert>DRAFT!</alert>")
```

#### `Bool.not() -> Bool`

Negates a boolean value.


```superhtml
$page.draft.not()
```

#### `Bool.and(Bool, [Bool...]) -> Bool`

Computes logical `and` between the receiver value and any other 
value passed as argument.

```superhtml
$page.draft.and($site.tags.len().eq(10))
```

#### `Bool.or(Bool, [Bool...]) -> Bool`

Computes logical `or` between the receiver value and any other value passed as argument.


```superhtml
$page.draft.or($site.tags.len().eq(0))
```

### Int

A signed 64-bit integer.

#### `Int.eq(Int) -> Bool`

Tests if two integers have the same value.


```superhtml
$page.wordCount().eq(200)
```

#### `Int.gt(Int) -> Bool`

Returns true if lhs is greater than rhs (the argument).


```superhtml
$page.wordCount().gt(200)
```

#### `Int.plus(Int) -> Int`

Sums two integers.


```superhtml
$page.wordCount().plus(10)
```

#### `Int.minus(Int) -> Int`

Subtracts the rhs from the lhs.


```superhtml
$page.wordCount().minus(12)
```

#### `Int.div(Int) -> Int`

Divides the receiver by the argument.


```superhtml
$page.wordCount().div(10)
```

#### `Int.byteSize() -> String`

Turns a raw number of bytes into a human readable string that
appropriately uses Kilo, Mega, Giga, etc.


```superhtml
$page.asset('photo.jpg').size().byteSize()
```

#### `Int.str() -> String`

Converts the number into a string, so that can be used for
functions that require a string argument.

```superhtml
$i18n.get!("current_page").fmt($loop.idx.str())
```

### Float

A 64bit float value.

### Iterator

An iterator.

Fields:

- `it` : Value — The current iteration variable.
- `idx` : Int — The current iteration index.
- `first` : Bool — True on the first iteration loop.
- `last` : Bool — True on the last iteration loop.
- `len` : Int — The length of the sequence being iterated.

#### `Iterator.up() -> Iterator`

In nested loops, accesses the upper `$loop`


```superhtml
$loop.up().it
```

### Array

An array of items.

Fields:

- `len` : Int — The length of the array.
- `empty` : Bool — True when len is 0.

#### `Array.toJson() -> String`

Serializes the array to a JSON string.

Use it to pass a collection into a typed island prop:
`prop-items="$page.custom.get('faq').toJson()"` (or with
`$site.data(...)`). The island's `Props` field — e.g.
`[]const Item` — is parsed from that JSON, so the whole list
arrives at once. The dynamic-attribute analogue of an inline
`:props='{ .items = [ ... ] }'` literal.

```superhtml
<island src="Faq.zig" prop-items="$page.custom.get('faq').toJson()"></island>
```

#### `Array.slice(Int, ?Int) -> [any]`

Slices an array from the first value (inclusive) to the
second value (exclusive).

The second value can be omitted and defaults to the array's
length, meaning that invoking `slice` with one argunent 
produces **suffixes** of the original sequence.

Note that negative values are not allowed at the moment.

```superhtml
$page.tags.slice(0,1)
```

#### `Array.at(Int) -> any`

Returns the value at the provided index. 

```superhtml
$page.tags.at(0)
```

#### `Array.first?() -> [any]`

Returns the the first value of the array or null if the array is empty. 

```superhtml
$page.tags.first?()
```

#### `Array.last?() -> [any]`

Returns the the last value of the array or null if the array is empty. 

```superhtml
$page.tags.last?()
```

### KV

A key-value pair.

Fields:

- `key` : String — The key string.
- `value` : Value — The corresponding value.

## Content directives

The `.smd` vocabulary. A directive is written as the TARGET of a Markdown
link, and applies to that link's text:

```markdown
## []($heading.id("intro")) Intro

[the home page]($link.site())

[that section]($link.page("docs/spa").ref("route-guards--gated-spas"))
```

An empty link text (`[]`) applies the directive to the element the link
sits in — which is how a heading gets an id without becoming a link.

### Functions on every directive

These four exist on every directive below, whatever its kind, and are
written with that directive's own name in front: `$heading.id("intro")`,
`$link.id("x")`, `$image.title("…")` are all the same function.

#### `$<directive>.id(str) -> anydirective`

Sets the unique identifier field of this directive.

#### `$<directive>.attrs(str, [str...]) -> anydirective`

Appends to the attributes field of this Directive.

#### `$<directive>.title(str) -> anydirective`

Title for this directive, mostly used as metadata that does
not get rendered directly in the page.

#### `$<directive>.data(str, str, [str...]) -> anydirective`

Adds data key-value pairs of a Directive.

In SuperHTML data key-value pairs can be accessed 
programmatically in a template when rendering
a section, while data will turn into `data-foo`
attributes otherwise. 

### `$section`

A content section, used to define a portion of content
that can be rendered individually by a template. 

### `$block`

When placed at the beginning of a Markdown quote block, the quote 
block becomes a styleable container for elements.

SuperHTML will automatically give the class `block` when rendering 
Block directives.

Example:
```markdown
>[]($block)
>This is now a block.
>Lorem ipsum.
```

>\[]\(`$block`)
>This is now a block.
>Lorem ipsum.

Differently from Sections, Blocks cannot be rendered independently 
and can be nested.

Example:
```markdown
>[]($block)
>This is now a block.
>
>>[]($block.attrs('padded'))
>>This is a nested block.
>>
>
>back to the outer block
```

>\[]\(`$block`)
>This is now a block.
>
>>\[]\(`$block.attrs('padded')`)
>>This is a nested block.
>
>back to the outer block

A block can optionally wrap a Markdown heading element. In this case  
the generated Block will be rendered with two separate sub-containers: 
one for the block title and one for the body.

Example:
```markdown
># [Warning]($block.attrs('warning'))
>This is now a block note.
>Lorem ipsum.
```
># \[Warning]\(`$block.attrs('warning')`)
>This is now a block note.
>Lorem ipsum.


By calling `collapsible` you can generate `<details>` elements:


Example:
```markdown
># [Example]($block.collapsible(false))
>The title becomes the `<summary>` element!
>Lorem ipsum.
```
># \[Example]\(`$block.collapsible(false)`)
>The title becomes the `<summary>` element!
>Lorem ipsum.



#### `$block.collapsible(Bool) -> anydirective`

Render the block as a collapsible element. The argument defines
if the block should be open by default or not.

### `$heading`

Allows giving an id and attributes to a heading element.

Example:
```markdown
# [Title]($heading.id('foo').attrs('bar', 'baz'))
```

This will be rendered by SuperHTML as:
```html
<h1 id="foo" class="bar baz">Title</h1>
```

### `$image`

An embedded image.

Any text placed between `[]` will be used as a caption for the image.

Example:
```markdown
[This is the caption]($image.asset('foo.jpg'))
```

#### `$image.alt(String) -> anydirective`

An alternative description for this image that accessibility
tooling can access.

#### `$image.linked(Bool) -> anydirective`

Wraps the image in a link to itself.

#### `$image.size(int, int) -> Image`

Sets the width and/or height of the image.

When both dimensions are non-zero, the image will be resized to exactly those dimensions:
```markdown
[Image caption]($image.asset('example.jpg').size(800, 600))
```

To specify width while maintaining aspect ratio, set height to 0:
```markdown
[Image caption]($image.asset('example.jpg').size(800, 0))
```

To specify height while maintaining aspect ratio, set width to 0:
```markdown
[Image caption]($image.asset('example.jpg').size(0, 600))
```


#### `$image.url(str) -> anydirective`

Sets the source location of this directive to an external URL.

#### `$image.asset(str) -> anydirective`

Sets the source location of this directive to a page asset.

#### `$image.siteAsset(str) -> anydirective`

Sets the source location of this directive to a site asset.

#### `$image.buildAsset(str) -> anydirective`

Sets the source location of this directive to a build asset.

### `$video`

An embedded video.

Any text placed between `[]` will be used as a caption for the video.

Example:
```markdown
[This is the caption]($video.asset('foo.webm'))
```

#### `$video.loop(Bool) -> anydirective`

If true, the video will seek back to the start upon reaching the 
end.

#### `$video.muted(Bool) -> anydirective`

If true, the video will be silenced at start. 

#### `$video.autoplay(Bool) -> anydirective`

If true, the video will start playing automatically. 

#### `$video.controls(Bool) -> anydirective`

If true, the video will display controls (e.g. play/pause, volume). 

#### `$video.pip(Bool) -> anydirective`

If **false**, clients shouldn't try to display the video in a 
Picture-in-Picture context.

#### `$video.url(str) -> anydirective`

Sets the source location of this directive to an external URL.

#### `$video.asset(str) -> anydirective`

Sets the source location of this directive to a page asset.

#### `$video.siteAsset(str) -> anydirective`

Sets the source location of this directive to a site asset.

#### `$video.buildAsset(str) -> anydirective`

Sets the source location of this directive to a build asset.

### `$link`

A link.

#### `$link.url(str) -> anydirective`

Sets the source location of this directive to an external URL.

#### `$link.asset(str) -> anydirective`

Sets the source location of this directive to a page asset.

#### `$link.siteAsset(str) -> anydirective`

Sets the source location of this directive to a site asset.

#### `$link.buildAsset(str) -> anydirective`

Sets the source location of this directive to a build asset.

#### `$link.site(?str) -> anydirective`

Sets the source location of this directive to the site's home page.

The only optional argument is the locale code for mulitlingual
websites. In mulitlingual websites, the locale code defaults to
the same locale of the current content file.

#### `$link.page(str, ?str) -> anydirective`

Sets the source location of this directive to a page.

The first argument is a page path, while the second, optional 
argument is the locale code for mulitlingual websites. In 
mulitlingual websites, the locale code defaults to the same
locale of the current content file.

The path is relative to the content directory and should exclude
the markdown suffix as Zigapagos will automatically infer which file
naming convention is used by the target page. 

For example, the value 'foo/bar' will be automatically
matched by Zigapagos with either:
  - content/foo/bar.smd
  - content/foo/bar/index.smd

To link to the website's home page, see `$link.site()`

#### `$link.sibling(str, ?str) -> anydirective`

Same as `page()`, but the reference is relative to the section
the current page belongs to.

># \[NOTE]\(`$block.attrs('note')`)
>While section pages define a section, *as pages* they don't
>belong to the section they define.

#### `$link.sub(str, ?str) -> anydirective`

Same as `page()`, but the reference is relative to the current 
page.

Only works on Section pages (i.e. pages with a `index.smd`
filename).

#### `$link.new(Bool) -> anydirective`

When `true` it asks readers to open the link in a new window or 
tab.

#### `$link.alternative(str) -> anydirective`

When linking to a content page, allows to link to a specific
alternative version of the page, which can be particularly
useful when referencing the RSS feed version of a page.

The string argument is the name of an alrenative as defined 
in the page's `alternatives` frontmatter property.

#### `$link.ref(str) -> anydirective`

Deep-links to a specific element (like a section or any
directive that specifies an `id`) of either the current
page or a target page set with `page()`.

Zigapagos tracks all ids defined in content files so referencing 
an id that doesn't exist will result in a build error.

Zigapagos does not track ids defined inside of templates so 
use `unsafeRef` to deep-link to those. 

#### `$link.unsafeRef(str) -> anydirective`

Like `ref` but Zigapagos will not perform any id checking.

Can be used to deep-link to ids specified in templates. 

### `$code`

An embedded piece of code.

Any text placed between `[]` will be used as a caption for the snippet.

Example:
```markdown
[This is the caption]($code.asset('foo.zig'))
```

#### `$code.asset(str) -> anydirective`

Sets the source location of this directive to a page asset.

#### `$code.siteAsset(str) -> anydirective`

Sets the source location of this directive to a site asset.

#### `$code.buildAsset(str) -> anydirective`

Sets the source location of this directive to a build asset.

#### `$code.language(String) -> anydirective`

Sets the language of this code snippet, which is also used for
syntax highlighting.

#### `$code.lines(int, int) -> anydirective`

 Limit the included code asset to the specified lines.
 The second argument is inclusive.

 ```
 []($code.asset("main.zig").lines(10, 15))
 ```
 This will include only lines 10 - 15 from the main.zig asset file.

### `$text`

Allows giving an id and attributes to some text.

Example:
```markdown
Hello [World]($text.id('foo').attrs('bar', 'baz'))!
```

This will be rendered by SuperHTML as:
```html
Hello <span id="foo" class="bar baz">World</span>!
```

### `$mathtex`

Outputs the given LaTeX formula as a script tag that can be rendered
at runtime by JavaScript tools such as \[Katex]\(https://katex.org),
\[MathJax]\(https://www.mathjax.org/), \[Temml]\(https://temml.org/), etc.
Note that the formula must be enclosed in backticks to avoid
collisions with other SuperMD syntax.

This JS based solution is temporary. Zigapagos will eventually implement
its own way of outputting MathML at buildtime so that clients won't 
need to have JS enabled.

To render math formulas as separate blocks, use this syntax:

    ```=mathtex
    x+\sqrt{1-x^2}
    ```

Example:
```markdown
Here's some [`x+\sqrt{1-x^2}`]($mathtex) math. 
```

This will be rendered by SuperHTML as:
```html
Here's some <script type="math/tex">x+\sqrt{1-x^2}</script> math.
```

It's then the user's responsibility to wire in the necessary JS/CSS
dependencies to obtain runtime rendering of math formulas.

The Zigapagos sample site shows a basic setup that uses Temml.

