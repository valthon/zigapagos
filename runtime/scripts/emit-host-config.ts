import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

export type Manifest = {
  base: string;
  deploy_target: "zigbase" | "nginx" | "apache";
  /** The URL path a host mounts this site's output tree under, e.g. "/myrepo"
   *  — one leading slash, no trailing slash. `""`-or-absent for an unprefixed
   *  (root-mounted) site, in which case every emitter's output is
   *  byte-identical to before this field existed.
   *
   *  Every OTHER route value in this manifest (`base`, `static[]`,
   *  `dynamic[].pattern`, `dynamic[].shell`, `fallback`) stays TREE-RELATIVE:
   *  it describes a position inside the built output tree, which contains no
   *  prefix directory regardless of where a host mounts it. This field is
   *  applied by each emitter according to ITS OWN semantics — some contexts
   *  match the real (prefixed) request path, others resolve relative to the
   *  (unprefixed) output tree — see `emitZigbase`'s doc comment for the
   *  sharpest example of that split. */
  url_path_prefix?: string;
  static: string[];
  dynamic: { pattern: string; shell: string }[];
  fallback: string;
  /** The SPA's entry bundle URL — and, unlike every route value above, it is
   *  **already prefixed** by the time it reaches here (as are the `chunks` map's
   *  VALUES), because `renderShell` bakes both verbatim into the shell's
   *  `<script>` and `modulepreload` tags. So this manifest carries two
   *  conventions: route values are tree-relative, these are request URLs. Do not
   *  resolve `bundle` against the output tree, and do not run it through
   *  `withPrefix` — either would double-count the prefix. */
  bundle: string;
};

/** A file to write into the SPA namespace directory (sibling of routing-manifest.json). */
export type EmittedFile = { name: string; content: string };

// ── Route-value validation + per-language encoding ──────────────────────────
// Every route value below is interpolated into THREE different output languages:
// an nginx `location`/`try_files`, an Apache `RewriteRule` REGEX plus its rewrite
// target, and a generated ZIG STRING LITERAL. None of them are attacker-supplied
// — they come from the site author's own `.spa.tsx`, which the sidecar already
// executes at build time — but an honest author's legitimate route can still
// emit config that means something other than what they wrote. So: validate the
// charset ONCE, loudly, naming the offending value (mirroring what
// `assertSafeStaticSegment` does for staticPaths in src/router.ts), then encode
// per-emitter for what legitimately survives — the "." in "/docs/v1.0/:page" is
// VALID input yet matches ANY character in an Apache regex, so validation alone
// cannot fix Apache.

/** A concrete URL path: "/" followed by URL-unreserved path characters. */
const SAFE_PATH_RE = /^\/[A-Za-z0-9._~\-/]*$/;
/** A route PATTERN: a safe path that may also carry ":param" and "*" segments. */
const SAFE_PATTERN_RE = /^\/[A-Za-z0-9._~\-/:*]*$/;

function assertSafeRouteValue(value: string, re: RegExp, what: string): void {
  if (!re.test(value)) {
    throw new Error(
      `emit-host-config: ${what} ${JSON.stringify(value)} is not a safe URL path — it must start ` +
        `with "/" and use only A-Za-z0-9 . _ ~ - /${re === SAFE_PATTERN_RE ? " : *" : ""}. ` +
        `Route values are interpolated into generated nginx, Apache and Zig config.`,
    );
  }
  if (value.split("/").includes("..")) {
    throw new Error(
      `emit-host-config: ${what} ${JSON.stringify(value)} contains a ".." segment, which escapes ` +
        `the site directory when a host resolves the emitted rule.`,
    );
  }
}

/** Validate every route value a manifest feeds into generated host config.
 *  Called by all three emitters, so no emitter can be reached unvalidated. */
export function assertSafeManifest(m: Manifest): void {
  assertSafeRouteValue(m.base, SAFE_PATH_RE, "manifest base");
  assertSafeRouteValue(m.fallback, SAFE_PATH_RE, "manifest fallback");
  // "" and undefined are the two unprefixed spellings; SAFE_PATH_RE requires a
  // leading "/" so it cannot validate either of those, and doesn't need to.
  if (m.url_path_prefix) {
    assertSafeRouteValue(m.url_path_prefix, SAFE_PATH_RE, "manifest url_path_prefix");
    // SAFE_PATH_RE alone admits "/myrepo/" and "/", either of which yields a
    // doubled slash once concatenated onto a leading-"/" route value
    // (`location "/myrepo//app/"`, `.match = "//app/**"`) — a selector that
    // matches no request path, so the SPA would 404 rather than fail loudly.
    // The producer cannot emit those (src/spa.zig normalizes), which is exactly
    // why the validator has to: its whole job is to be the guard for a manifest
    // this build did not write.
    if (m.url_path_prefix.endsWith("/")) {
      throw new Error(
        `emit-host-config: manifest url_path_prefix ${JSON.stringify(m.url_path_prefix)} must not ` +
          `end with "/" — it is concatenated onto route values that already start with one, and ` +
          `the resulting "//" matches no request path.`,
      );
    }
  }
  for (const d of m.dynamic) {
    assertSafeRouteValue(d.pattern, SAFE_PATTERN_RE, "dynamic route pattern");
    assertSafeRouteValue(d.shell, SAFE_PATH_RE, "dynamic route shell");
  }
}

/**
 * Escape PCRE metacharacters so a literal path segment can be spliced into an
 * Apache `RewriteRule` pattern and match only itself.
 *
 * **This is a PCRE escaper, not a JavaScript one, and the distinction is the
 * reason it exists rather than `RegExp.escape`.** The only consumer is
 * `emitApache` below; mod_rewrite compiles its patterns with PCRE2, a different
 * regex dialect from ECMAScript. `RegExp.escape` is specified to produce a
 * string safe in any *ECMAScript* `RegExp` position — its guarantee simply does
 * not extend to PCRE, so any PCRE-correctness it happens to have is an
 * observation about today's PCRE2, not a contract. (Empirically it *is* accepted:
 * `emit-host-config.test.ts` checks both spellings against a real Perl-compatible
 * engine, including the `\x76`-followed-by-`1` hex-digit adjacency in
 * `RegExp.escape("v1.0")`. That is why this is a readability call, not a
 * correctness one — see below.)
 *
 * The second reason is product quality: the file this lands in is a deployed
 * `.htaccess` that operators read and edit. `RegExp.escape` hex-escapes the
 * leading character unconditionally plus its whole punctuator set, so the same
 * rule reads
 *
 *     RewriteRule ^\x61pp/.*$ /app/index.html [L]      # RegExp.escape
 *     RewriteRule ^app/.*$    /app/index.html [L]      # escapePcre
 *
 * The first does not just look worse, it is misleading — the operator cannot see
 * which URL path the rule matches, and this file is their interface to the SPA's
 * routing. There is no offsetting benefit, because for the charset
 * `assertSafeManifest` actually admits (`A-Za-z0-9 . _ ~ - /`) the ONLY character
 * needing an escape in PCRE is `.`; `-` is a range metacharacter solely inside
 * `[...]`, and `/` is a delimiter only in a regex *literal*, which a config file
 * has none of.
 *
 * Escapes the full PCRE metacharacter set anyway — `. * + ? ^ $ { } ( ) | [ ] \`
 * — rather than just the `.` the validator lets through, on the same principle
 * `zigStringLiteral` below is written to: a code generator that can only emit
 * well-formed output is the safer contract, and it must not silently depend on a
 * validator that a future caller might bypass.
 *
 * What it deliberately does NOT cover: Apache's *config-file tokenizer*.
 * Whitespace and quotes would split or unbalance the directive before PCRE ever
 * sees the pattern, and no regex escaping can fix that — `assertSafeManifest`
 * (called first thing in `emitApache`) is the guard for those, and it rejects
 * every character outside the charset above.
 */
export function escapePcre(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Quote a value as a single nginx token. nginx strips the quotes at parse time,
 *  so the directive still sees the exact path — but the token can no longer end
 *  early on whitespace or `;` the way a bare interpolation could. */
function nginxQuote(s: string): string {
  return `"${s.replace(/(["\\])/g, "\\$1")}"`;
}

/** Render `s` as a Zig double-quoted string literal (quotes included). Makes the
 *  `.static_routes` emitter correct on its own terms rather than relying on the
 *  caller having validated — a code generator that can only emit well-formed
 *  output is the safer contract. */
export function zigStringLiteral(s: string): string {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    if (ch === "\\" || ch === '"') out += "\\" + ch;
    else if (c >= 0x20 && c < 0x7f) out += ch;
    else if (c <= 0xff) out += "\\x" + c.toString(16).padStart(2, "0");
    else out += "\\u{" + c.toString(16) + "}";
  }
  return out + '"';
}

/** Dir portion of a "/app/club/:id" pattern → "/app/club/"; a root-level dynamic
 *  route ("/:id") yields "/", never "//" (which matches no request path). */
function patternDir(pattern: string): string {
  const segs = pattern.split("/").filter(Boolean);
  const keep: string[] = [];
  for (const s of segs) { if (s.startsWith(":") || s === "*") break; keep.push(s); }
  return keep.length === 0 ? "/" : "/" + keep.join("/") + "/";
}

/** Apply a manifest's `url_path_prefix` to a tree-relative path FOR CONTEXTS
 *  THAT MATCH OR REDIRECT AGAINST THE REAL REQUEST PATH — nginx `location`
 *  selectors and `try_files` targets, ZigBase `.match` patterns. A no-op when
 *  `prefix` is `""` (the manifest's unprefixed spelling), which is what keeps
 *  every existing site's emitted output byte-identical.
 *
 *  Plain concatenation is correct, not merely convenient: `prefix` is
 *  contractually one leading slash with no trailing slash, and every `path`
 *  this is called with already starts with exactly one "/" (never "//") by
 *  construction — `patternDir`/the `base.replace(/\/+$/, "") + "/"` idiom
 *  below collapse to a single "/" at the root, so concatenating never
 *  produces a doubled slash. Do NOT use this on a value that resolves against
 *  the OUTPUT TREE rather than the request path (`.serve`, `fallback`,
 *  `d.shell` as filesystem-relative targets) — see `emitZigbase`'s doc
 *  comment for why that split is deliberate. */
function withPrefix(prefix: string, path: string): string {
  return prefix ? prefix + path : path;
}

export function emitNginx(m: Manifest): EmittedFile[] {
  assertSafeManifest(m);
  const prefix = m.url_path_prefix ?? "";
  // A root-mounted SPA (base "/") must emit `location /`, NOT `location //`:
  // "//" matches no request path, so every deep link would 404 instead of
  // reaching the shell. Stripping the trailing slash before re-adding one also
  // normalizes an author-written "/app/". (With a prefix, the same guard
  // keeps this "location /myrepo/", never "/myrepo//" — see withPrefix.)
  const baseDir = m.base.replace(/\/+$/, "") + "/";
  const lines: string[] = [
    // Say where the tree must sit, the way the Apache header does. The
    // selectors and try_files targets below are REQUEST paths carrying the
    // prefix, while the files they name live in a tree that has no prefix
    // directory — so they are only correct if the server resolves
    // `<prefix>/…` to `<the built tree>/…`, i.e. the tree is mounted at
    // <docroot>/<prefix>/ (or an `alias` achieves the same mapping). Getting
    // that wrong is a 404 on every deep link, and nothing in the config itself
    // reveals the assumption.
    prefix
      ? `# Generated by emit-host-config.ts for SPA namespace ${m.base}, mounted at URL ` +
        `prefix ${prefix} — serve the built tree from <docroot>${prefix}/ (or alias ${prefix}/ to it)`
      : `# Generated by emit-host-config.ts for SPA namespace ${m.base}`,
    `location ${nginxQuote(withPrefix(prefix, baseDir))} {`,
    `    try_files $uri $uri/ ${nginxQuote(withPrefix(prefix, m.fallback))};`,
    `}`,
  ];
  for (const d of m.dynamic) {
    const dir = patternDir(d.pattern);
    lines.push(
      `location ${nginxQuote(withPrefix(prefix, dir))} {`,
      // The fallback/shell here are try_files' TARGETS, not filesystem paths:
      // try_files treats a "/"-leading last argument as an internal redirect
      // URI, which nginx resolves by re-running location matching — so it
      // must carry the prefix too, or it falls through to a different (or no)
      // location block and 404s instead of reaching the shell.
      `    try_files $uri ${nginxQuote(withPrefix(prefix, d.shell))} ${nginxQuote(withPrefix(prefix, m.fallback))};`,
      `}`,
    );
  }
  return [{ name: "nginx.nginx.conf", content: lines.join("\n") + "\n" }];
}

/** Strip leading (and trailing) "/" — RewriteRule patterns in a per-directory
 * `.htaccess` context are matched WITHOUT the leading slash; rewrite TARGETS
 * (the second argument) keep their leading slash. */
function noSlashes(s: string): string {
  return s.replace(/^\/+/, "").replace(/\/+$/, "");
}

export function emitApache(m: Manifest): EmittedFile[] {
  assertSafeManifest(m);
  const prefix = m.url_path_prefix ?? "";
  const baseNoLeadingSlash = noSlashes(m.base);
  const lines: string[] = [
    prefix
      ? `# Generated by emit-host-config.ts for SPA namespace ${m.base}, mounted at URL ` +
        `prefix ${prefix} — install as <docroot>/.htaccess in the directory the host maps ` +
        `${prefix}/ to (see RewriteBase below)`
      : `# Generated by emit-host-config.ts for SPA namespace ${m.base} — install as <docroot>/.htaccess`,
    `RewriteEngine On`,
  ];
  if (prefix) {
    // RewriteBase is the documented mechanism for telling mod_rewrite the
    // URL-path this directory is mounted at. It does NOT affect RewriteRule
    // PATTERN matching (those already match correctly unprefixed: Apache
    // strips the containing directory's — now prefixed — URL-path before a
    // per-directory .htaccess ever sees the request path). It DOES affect a
    // RELATIVE substitution TARGET (no leading slash): mod_rewrite resolves
    // it as "<RewriteBase><target>" rather than auto-detecting the directory
    // URL, which is unreliable under Alias and exactly why RewriteBase exists.
    // That's why targets below drop their leading slash only in this branch —
    // it puts the prefix in ONE place instead of duplicating it into every
    // RewriteRule line. (A leading-slash-absolute target, the unprefixed
    // form's scheme, is reprocessed as a brand-new URL from the server root
    // instead — RewriteBase would not apply to it at all, so the two schemes
    // must not be mixed.)
    lines.push(`RewriteBase ${prefix}/`);
  }
  // Substitution targets: leading-slash-absolute when unprefixed (unchanged
  // from before this field existed); relative-to-RewriteBase when prefixed.
  const target = (path: string): string => (prefix ? noSlashes(path) : path);
  if (m.dynamic.length > 0) {
    lines.push(`# Dynamic route patterns → their prerendered shell`);
    for (const d of m.dynamic) {
      const dirNoLeadingSlash = noSlashes(patternDir(d.pattern));
      // The literal prefix is a PATH, not a regex: a legitimate "." (as in
      // "/docs/v1.0/:page") would otherwise match ANY character and rewrite
      // unrelated URLs like /docs/v1X0/… to this SPA shell. Only the ".*" we
      // append is meant as a metacharacter.
      const pattern = dirNoLeadingSlash ? `^${escapePcre(dirNoLeadingSlash)}/.*$` : `^.*$`;
      lines.push(
        `RewriteCond %{REQUEST_FILENAME} !-f`,
        `RewriteCond %{REQUEST_FILENAME} !-d`,
        `RewriteRule ${pattern} ${target(d.shell)} [L]`,
      );
    }
  }
  lines.push(
    `# Namespace fallback → the SPA shell`,
    `RewriteCond %{REQUEST_FILENAME} !-f`,
    `RewriteCond %{REQUEST_FILENAME} !-d`,
    `RewriteRule ${baseNoLeadingSlash ? `^${escapePcre(baseNoLeadingSlash)}/.*$` : `^.*$`} ${target(m.fallback)} [L]`,
  );
  return [{ name: "apache.htaccess", content: lines.join("\n") + "\n" }];
}

/** Our route patterns spell a trailing catch-all "*" (matches zero-or-more remaining
 * segments); ZigBase spells that terminal case "**". ":param" is identical in both.
 * (ZigBase's own "*" means one-or-more, so we must NOT emit a bare "*".) */
function toZigbaseMatch(pattern: string): string {
  const segs = pattern.split("/");
  if (segs.length > 0 && segs[segs.length - 1] === "*") segs[segs.length - 1] = "**";
  return segs.join("/");
}

/**
 * ZigBase >= 0.10.0 native SPA fallback (zigbase#183). Two tiers:
 *
 *  - Tier 1 (the shipped `zigbase serve` binary, zero config): a presence-only,
 *    empty `.spa` MARKER file placed in the namespace directory. ZigBase serves
 *    `<base>/index.html` (200) for any GET/HEAD miss at or below that directory —
 *    real files, `/api`, admin, and custom routes always win. This is all the
 *    stock binary needs; no manifest is read.
 *
 *  - Tier 2 (a CUSTOM ZigBase build): comptime `.static_routes` for per-pattern
 *    prerendered shells + exact rewrites. We can't install this (it's compiled
 *    into the app), so we emit a ready-to-paste snippet as a reference — analogous
 *    to the nginx/apache config files. It recovers the dedicated `_shell.html`
 *    first-paint that the marker alone can't (the marker always serves index.html).
 *
 * NOTE: this replaces the pre-0.10.0 `zigbase.zigbase.json` manifest copy, which
 * ZigBase never read — the `.spa` marker is the real contract.
 */
export function emitZigbase(m: Manifest): EmittedFile[] {
  assertSafeManifest(m);
  const prefix = m.url_path_prefix ?? "";
  const files: EmittedFile[] = [
    // Tier 1 — the marker ZigBase's static server reads. Presence-only, empty,
    // and its meaning is its LOCATION in the tree, not its content — a prefix
    // changes nothing here.
    { name: ".spa", content: "" },
  ];

  // Tier 2 — an OPTIONAL comptime snippet recovering the per-pattern shells.
  //
  // .match is prefixed: ZigBase matches it against the real REQUEST path, and
  // under a prefix that path carries the prefix. .serve is deliberately left
  // TREE-RELATIVE, unprefixed, even though that looks inconsistent next to a
  // prefixed .match on the same line: ZigBase resolves a route's .serve as
  // `root ++ "/" ++ trimStart(serve, "/")` (see `validateRouteTargetsDir` in
  // zigbase's src/static_files.zig) — i.e. against the SERVED ROOT DIRECTORY,
  // which holds the built output tree exactly as this build wrote it, with NO
  // prefix directory inside it (verified: a prefixed site's zig-out/site/
  // holds its route directories directly, no extra path segment for the
  // prefix). Prefixing .serve would make ZigBase look for
  // "<root>/<prefix><shell-path>", which does not exist.
  const routes: string[] = [];
  for (const d of m.dynamic) {
    routes.push(
      `    .{ .match = ${zigStringLiteral(withPrefix(prefix, toZigbaseMatch(d.pattern)))}, ` +
        `.serve = ${zigStringLiteral(d.shell)} },`,
    );
  }
  const baseNoTrailing = m.base.replace(/\/+$/, "");
  routes.push(
    `    .{ .match = ${zigStringLiteral(withPrefix(prefix, baseNoTrailing + "/**"))}, ` +
      `.serve = ${zigStringLiteral(m.fallback)} },`,
  );

  const exampleShell = m.dynamic[0]?.shell ?? `${baseNoTrailing}/<pattern>/_shell.html`;
  // Only present when prefixed, so the unprefixed snippet stays byte-identical.
  const prefixNote = prefix
    ? `// Mounted at URL prefix "${prefix}": .match patterns below are prefixed (they match\n` +
      `// the real request path); .serve targets deliberately stay tree-relative — ZigBase\n` +
      `// resolves .serve against the served root directory, which holds this build's\n` +
      `// output tree with no prefix directory in it. See emit-host-config.ts's emitZigbase\n` +
      `// doc comment if this split looks like a bug: it isn't.\n` +
      `//\n`
    : "";
  const snippet =
    `// ZigBase >= 0.10.0 comptime static_routes for SPA namespace "${m.base}".\n` +
    `//\n` +
    prefixNote +
    `// OPTIONAL — the shipped 'zigbase serve' binary needs NONE of this: the sibling\n` +
    `// '.spa' marker already serves ${m.fallback} for every miss under ${m.base}\n` +
    `// (deep links + hard refreshes). Use this only in a CUSTOM ZigBase build that wants\n` +
    `// the dedicated per-route prerendered shell on first paint (e.g. ${exampleShell})\n` +
    `// instead of the generic namespace shell.\n` +
    `//\n` +
    `// Paste into your App(.{ ... }) config. First match wins in declaration order;\n` +
    `// ':id' matches one segment, '**' matches zero-or-more trailing segments.\n` +
    `.static_routes = &.{\n` +
    `${routes.join("\n")}\n` +
    `},\n` +
    `// Declaring .static_routes turns the .spa marker OFF by default;\n` +
    `// set .enable_spa_marker = true to keep both (routes match first, marker is the residual fallback).\n`;
  files.push({ name: "zigbase.static_routes.zig", content: snippet });

  return files;
}

const EMITTERS: Record<string, (m: Manifest) => EmittedFile[]> = {
  nginx: emitNginx, apache: emitApache, zigbase: emitZigbase,
};

// ── Strict-CSP support ──────────────────────────────────────────────────────
// A `script-src` without `unsafe-inline` blocks our generated inline scripts
// (the `<script type="importmap">` and the `<script type="module">…mountSpa…`
// bootstrap). Their content is deterministic at build time, so we hash each and
// publish a `'sha256-…'` allow-list the operator merges into their CSP header.

export type CspTarget = "nginx" | "apache" | "zigbase";

/** sha256 of the EXACT inline text → the CSP `'sha256-<base64>'` hash-source
 * token, INCLUDING the wrapping single quotes the grammar requires (an unquoted
 * `sha256-…` is parsed as a HOST source, e.g. `http://sha256-…`, and ignored —
 * verified against real Chrome + Firefox). The browser hashes the literal UTF-8
 * bytes between a start tag's `>` and its matching close tag, so `content` must
 * be passed byte-for-byte as served. Serves `<script>` and `<style>` alike — CSP
 * hashing is the same sha256-of-exact-bytes rule for both element kinds. */
function inlineContentHash(content: string): string {
  return "'sha256-" + createHash("sha256").update(content, "utf8").digest("base64") + "'";
}

/** True for a `<script>` whose ATTRIBUTES mark it executable-or-importmap and
 * NOT external: `type="importmap"`, or `type="module"`/no `type`, and no `src`.
 * `type="application/json"` (our `data-z-props`/`data-z-slots` data blocks) and
 * any `src=` script (covered by `script-src 'self'`) return false. */
function isHashableInlineScript(attrs: string): boolean {
  if (/\bsrc\s*=/i.test(attrs)) return false; // external → 'self', not inline
  const t = attrs.match(/\btype\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i);
  const type = (t ? (t[1] ?? t[2] ?? t[3] ?? "") : "").trim().toLowerCase();
  return type === "" || type === "importmap" || type === "module";
}

/**
 * Walk `html` left-to-right and call `onElement` for every `<script>` and
 * `<style>` ELEMENT, in document order, with its attribute text and its exact
 * raw-text content.
 *
 * A hash allow-list is only as good as its agreement with what the browser
 * tokenizes, and a scan that is not comment- and raw-text-aware disagrees in
 * BOTH directions at once: it hashes text that is not an element, and — because
 * the bogus match consumes forward to the next close tag — it drops the hash of
 * a real element that follows. The deployed CSP then blocks markup the same
 * build emitted. (`src/islands/pass.zig` tokenizes with the same discipline for
 * the same reason.) So this walker mirrors the three tokenizer states that
 * matter here:
 *
 * - **Comment.** `<!--…-->` is skipped whole. A layout that merely *mentions*
 *   `<style>`/`<script>` in a comment — prose about the markup below it — must
 *   contribute no hash and must not swallow the element it describes.
 * - **Raw text.** Once inside `<script>`/`<style>` the content runs to the FIRST
 *   literal close tag, so a nested `<style>` inside a `<script type=
 *   "application/json">` data block is CONTENT, not an element. That case is
 *   real, not theoretical: `data-z-slots` JSON carries author HTML with only
 *   `</` escaped to `<\/` (`escapeScriptContent` in `src/islands/pass.zig`), so
 *   a slot holding a `<style>` leaves a literal, UNescaped `<style>` open tag in
 *   the page — visible to a naive regex, invisible to a browser.
 * - **Unterminated.** An unclosed comment or raw-text element means everything
 *   after it is content to the browser, so scanning stops rather than guessing.
 *
 * (Attribute values in our generated shells never contain `>`, so `[^>]*` for
 * the start tag is faithful.)
 */
function forEachRawTextElement(
  html: string,
  onElement: (name: "script" | "style", attrs: string, content: string) => void,
): void {
  // Constructed per call: a module-level /g regex carries `lastIndex` between
  // calls, which is exactly the kind of spooky state this file should not have.
  const open = /<!--|<(script|style)\b([^>]*)>/gi;
  for (let m = open.exec(html); m !== null; m = open.exec(html)) {
    if (m[0] === "<!--") {
      const end = html.indexOf("-->", m.index + "<!--".length);
      if (end < 0) return; // unterminated comment: the rest of the document is comment
      open.lastIndex = end + "-->".length;
      continue;
    }
    const name = m[1].toLowerCase() as "script" | "style";
    const from = m.index + m[0].length;
    const close = name === "script" ? /<\/script\s*>/gi : /<\/style\s*>/gi;
    close.lastIndex = from;
    const c = close.exec(html);
    if (c === null) return; // unterminated raw text: nothing after it is an element
    onElement(name, m[2], html.slice(from, c.index));
    open.lastIndex = c.index + c[0].length;
  }
}

/**
 * Scan HTML for inline scripts a strict CSP would block and return the SORTED,
 * DEDUPED set of `'sha256-…'` hashes over their exact content.
 */
export function scanInlineScriptHashes(htmlStrings: string[]): string[] {
  const hashes = new Set<string>();
  for (const html of htmlStrings) {
    forEachRawTextElement(html, (name, attrs, content) => {
      if (name === "script" && isHashableInlineScript(attrs)) hashes.add(inlineContentHash(content));
    });
  }
  return [...hashes].sort();
}

/**
 * Scan HTML for inline `<style>` ELEMENTS and return the SORTED, DEDUPED set of
 * `'sha256-…'` hashes over their exact content — the `style-src-elem` analogue
 * of `scanInlineScriptHashes` above.
 *
 * Style ATTRIBUTES (`style="…"` on an element) are NOT covered here — a CSP
 * hash-source can only allow-list `<style>`/`<script>` ELEMENT content, never an
 * attribute value (that would need `'unsafe-hashes'`, a broader grant this
 * emitter does not opt into). That is exactly why `style-src-attr` below stays
 * `'unsafe-inline'`: the framework's `display:contents` slot-wrapper attributes
 * have no hash-based alternative.
 */
export function scanInlineStyleHashes(htmlStrings: string[]): string[] {
  const hashes = new Set<string>();
  for (const html of htmlStrings) {
    forEachRawTextElement(html, (name, _attrs, content) => {
      if (name === "style") hashes.add(inlineContentHash(content));
    });
  }
  return [...hashes].sort();
}

// ── External head origins ──────────────────────────────────────────────────
// `spa.head` may reference external origins the build can plainly see (a
// Google Fonts stylesheet + its `preconnect`); those entries render into every
// shell as `<link>` tags. A CSP that omits them contradicts the HTML the same
// build step emitted — deploy it verbatim and the browser blocks the fonts.
//
// Rule (simple + predictable, documented in docs/spa.md): every EXTERNAL
// origin referenced by a `<link href="…">` in the built HTML is unioned into
// BOTH `style-src-elem` and `font-src`. This covers the pragmatic font pattern in
// one stroke — the stylesheet origin (fonts.googleapis.com) and the font-file
// origin its `preconnect` names (fonts.gstatic.com) both end up allowed in
// both directives. `script-src` is never widened. Root-relative hrefs are
// `'self'` and contribute nothing.

/** The lowercased `scheme://host[:port]` origin of an absolute http(s) URL —
 * or of a protocol-relative one (`//host/…`), whose scheme defaults to
 * `https:` for the emitted origin (a strict-CSP deployment serves over https,
 * so that's what the browser resolves the href to). Null for anything else
 * (root-relative, data:, other schemes, …). */
function externalOrigin(href: string): string | null {
  const m = /^(https?:)?\/\/([^/?#]+)/i.exec(href);
  return m ? `${m[1] ?? "https:"}//${m[2]}`.toLowerCase() : null;
}

/**
 * Scan HTML for `<link>` tags with an absolute external `href` and return the
 * SORTED, DEDUPED set of their origins. Attribute values in our generated
 * shells are HTML-escaped (`&` → `&amp;`), which can only occur in the
 * query/fragment — after the origin — so unescaping is unnecessary for the
 * origin match, but hrefs are still unescaped for robustness.
 */
export function scanExternalLinkOrigins(htmlStrings: string[]): string[] {
  const origins = new Set<string>();
  const re = /<link\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/gi;
  for (const html of htmlStrings) {
    for (let m = re.exec(html); m !== null; m = re.exec(html)) {
      const href = (m[1] ?? m[2] ?? m[3] ?? "").replace(/&amp;/g, "&");
      const o = externalOrigin(href);
      if (o) origins.add(o);
    }
  }
  return [...origins].sort();
}

/** The site-wide CSP header VALUE. `script-src` is strict — `'self'` plus the
 * inline-script hashes, NO `unsafe-inline` (that's the XSS-critical directive
 * and the whole point of hashing).
 *
 * `<style>`/`<link>` are governed by the CSP3 split directives instead of a
 * single blanket `style-src` (issue #130): `style-src-elem` stays just as
 * strict as `script-src` — `'self'` plus a `'sha256-…'` per unique inline
 * `<style>` element plus the folded external `<link>` origins, NO
 * `unsafe-inline` — because `<style>` element content CAN be hashed exactly
 * like a `<script>`. Only `style-src-attr` carries `'unsafe-inline'`, because
 * the framework emits inline `style="display:contents"` ATTRIBUTES on island
 * slot wrappers that a hash-source cannot cover (hashes apply to elements, not
 * attributes — reaching an attribute needs the broader `'unsafe-hashes'`,
 * which this emitter does not opt into). Attribute-style injection is far
 * lower risk than script injection, so this confines the one remaining lenient
 * grant to exactly the surface that needs it (verified: island + SPA pages
 * then serve with zero violations, elements included).
 *
 * There is deliberately NO bare `style-src` fallback line: the issue asks to
 * drop the blanket grant, and a lenient `style-src` alongside the split would
 * put `unsafe-inline` back in the header for any browser preferring it. The
 * accepted tradeoff is that a browser without CSP3 elem/attr support (pre-Chrome
 * 75, pre-Firefox 108, pre-Safari 15.4) falls back to `default-src 'self'` for
 * styles — external stylesheets and inline style attributes degrade there,
 * cosmetically, on an already-obsolete browser; see docs/spa.md.
 *
 * `linkOrigins` is the `scanExternalLinkOrigins` set: each origin is unioned
 * into `style-src-elem` AND a `font-src` (emitted only when the set is
 * non-empty, keeping the no-external-heads value byte-identical to before —
 * `font-src` then falls back to `default-src 'self'`). `styleHashes` is the
 * `scanInlineStyleHashes` set. */
export function cspHeaderValue(hashes: string[], linkOrigins: string[] = [], styleHashes: string[] = []): string {
  const scriptSrc = ["'self'", ...hashes].join(" ");
  const styleSrcElem = ["'self'", ...styleHashes, ...linkOrigins].join(" ");
  const fontSrc = linkOrigins.length === 0
    ? ""
    : `; font-src ${["'self'", ...linkOrigins].join(" ")}`;
  return `default-src 'self'; script-src ${scriptSrc}; style-src-elem ${styleSrcElem}; style-src-attr 'unsafe-inline'${fontSrc}; object-src 'none'; base-uri 'self'`;
}

/** One host-specific CSP artifact (site-wide, host-agnostic value). */
export function emitCsp(hashes: string[], target: CspTarget, linkOrigins: string[] = [], styleHashes: string[] = []): EmittedFile {
  const value = cspHeaderValue(hashes, linkOrigins, styleHashes);
  switch (target) {
    case "nginx":
      return {
        name: "csp.nginx.conf",
        content:
          `# Generated by emit-host-config.ts — strict Content-Security-Policy for the\n` +
          `# site's deterministic inline scripts and styles (importmap + SPA bootstrap,\n` +
          `# plus any inline <style> elements), allow-listed by sha256 hash. Merge into\n` +
          `# the server{}/location{} that serves the site.\n` +
          `add_header Content-Security-Policy "${value}" always;\n`,
      };
    case "apache":
      return {
        name: "csp.apache.conf",
        content:
          `# Generated by emit-host-config.ts — strict Content-Security-Policy for the\n` +
          `# site's deterministic inline scripts and styles (importmap + SPA bootstrap,\n` +
          `# plus any inline <style> elements), allow-listed by sha256 hash. Install in\n` +
          `# <docroot>/.htaccess or a <Directory> block (requires mod_headers).\n` +
          `Header set Content-Security-Policy "${value}"\n`,
      };
    case "zigbase":
      return {
        name: "csp.zigbase.txt",
        content:
          `# Generated by emit-host-config.ts — strict Content-Security-Policy for the\n` +
          `# site's deterministic inline scripts and styles (importmap + SPA bootstrap,\n` +
          `# plus any inline <style> elements), allow-listed by sha256 hash. Set this\n` +
          `# response header in your ZigBase App config (e.g. a global .headers entry)\n` +
          `# so every served page carries it.\n` +
          `Content-Security-Policy: ${value}\n`,
      };
  }
}

/** All three site-wide CSP artifacts for a scanned HTML set (operators pick the
 * file for their host; the header value is identical across targets). */
export function emitAllCsp(hashes: string[], linkOrigins: string[] = [], styleHashes: string[] = []): EmittedFile[] {
  return (["nginx", "apache", "zigbase"] as CspTarget[]).map((t) => emitCsp(hashes, t, linkOrigins, styleHashes));
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  let site = "";
  let override = "";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--site") site = args[++i] ?? "";
    else if (args[i] === "--target") override = args[++i] ?? "";
  }
  if (!site) { console.error("Usage: emit-host-config.ts --site <outputDir> [--target zigbase|nginx|apache]"); process.exit(1); }

  const glob = new Bun.Glob("**/routing-manifest.json");
  let count = 0;
  for (const rel of glob.scanSync({ cwd: site })) {
    const path = `${site}/${rel}`;
    const m: Manifest = JSON.parse(readFileSync(path, "utf8"));
    const target = override || m.deploy_target || "zigbase";
    const emit = EMITTERS[target];
    if (!emit) { console.error(`unknown deploy_target: ${target}`); process.exit(1); }
    // The namespace dir (manifest lives at <dir>/routing-manifest.json).
    const dir = path.slice(0, path.length - "routing-manifest.json".length); // keeps trailing "/"
    for (const f of emit(m)) {
      const outPath = dir + f.name;
      writeFileSync(outPath, f.content, "utf8");
      console.log(`emit-host-config: wrote ${outPath} (${target})`);
    }
    count++;
  }
  if (count === 0) console.log(`emit-host-config: no routing-manifest.json under ${site}`);

  // Site-wide CSP (independent of routing manifests): scan EVERY page under the
  // site once, hash its inline importmap/bootstrap scripts, and write all three
  // host CSP artifacts at the site root. Runs even for island-only sites (no
  // manifest), so a strict-CSP deployment serves them with zero violations.
  const htmlGlob = new Bun.Glob("**/*.html");
  const htmls: string[] = [];
  for (const rel of htmlGlob.scanSync({ cwd: site })) {
    htmls.push(readFileSync(`${site}/${rel}`, "utf8"));
  }
  const hashes = scanInlineScriptHashes(htmls);
  // Inline <style> ELEMENTS get their own hash set (style-src-elem) — see
  // scanInlineStyleHashes's doc comment for why attributes are out of scope.
  const styleHashes = scanInlineStyleHashes(htmls);
  // External origins referenced by <link> tags (spa.head renders
  // into every shell) must be allowed by the same CSP, or the emitted conf
  // blocks resources the emitted HTML loads.
  const linkOrigins = scanExternalLinkOrigins(htmls);
  for (const f of emitAllCsp(hashes, linkOrigins, styleHashes)) {
    const outPath = `${site}/${f.name}`;
    writeFileSync(outPath, f.content, "utf8");
    console.log(`emit-host-config: wrote ${outPath} (csp, ${hashes.length} inline-script hashes, ${styleHashes.length} inline-style hashes, ${linkOrigins.length} external link origins)`);
  }
}
