import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  emitNginx, emitApache, emitZigbase, assertSafeManifest, zigStringLiteral, escapePcre,
  scanInlineScriptHashes, scanInlineStyleHashes, scanExternalLinkOrigins, cspHeaderValue, emitCsp, emitAllCsp,
  IMMUTABLE_CACHE_CONTROL, REVALIDATE_CACHE_CONTROL, FINGERPRINT_SUFFIX_PATTERN,
  collectChunkPaths, emitCache, emitAllCache,
  type Manifest,
} from "./emit-host-config.ts";

const m: Manifest = {
  base: "/app",
  deploy_target: "nginx",
  static: ["/app/", "/app/booking/"],
  dynamic: [{ pattern: "/app/club/:id", shell: "/app/club/_shell.html" }],
  fallback: "/app/index.html",
  bundle: "/spa/app.js",
};

test("nginx emits a catch-all try_files for the base and each dynamic dir", () => {
  const [file] = emitNginx(m);
  expect(file.name).toBe("nginx.nginx.conf");
  // Route values are emitted as QUOTED nginx tokens (nginx strips the quotes at
  // parse time, so the directive still sees the exact path).
  expect(file.content).toContain(`location "/app/" {`);
  expect(file.content).toContain(`try_files $uri $uri/ "/app/index.html";`);
  expect(file.content).toContain(`location "/app/club/" {`);
  expect(file.content).toContain(`try_files $uri "/app/club/_shell.html" "/app/index.html";`);
});

test("apache emits valid mod_rewrite directives (no <Directory>, which is forbidden in .htaccess)", () => {
  const [file] = emitApache(m);
  expect(file.name).toBe("apache.htaccess");
  expect(file.content).toContain("RewriteEngine On");
  expect(file.content).toContain("RewriteRule ^app/club/.*$ /app/club/_shell.html [L]");
  expect(file.content).toContain("RewriteRule ^app/.*$ /app/index.html [L]");
  expect(file.content).not.toContain("<Directory");
});

test("zigbase emits a presence-only .spa marker (ZigBase >= 0.10.0 reads this, not a manifest)", () => {
  const files = emitZigbase(m);
  const marker = files.find((f) => f.name === ".spa");
  expect(marker).toBeDefined();
  expect(marker!.content).toBe(""); // presence-only: contents are ignored
  // The stale zigbase.zigbase.json manifest copy must NOT be emitted anymore.
  expect(files.some((f) => f.name.endsWith(".json"))).toBe(false);
});

test("zigbase also emits an optional comptime static_routes snippet for per-pattern shells", () => {
  const snippet = emitZigbase(m).find((f) => f.name === "zigbase.static_routes.zig");
  expect(snippet).toBeDefined();
  expect(snippet!.content).toContain(".static_routes = &.{");
  // dynamic route → its dedicated shell, then the namespace fallback (first-match-wins order)
  expect(snippet!.content).toContain(`.{ .match = "/app/club/:id", .serve = "/app/club/_shell.html" },`);
  expect(snippet!.content).toContain(`.{ .match = "/app/**", .serve = "/app/index.html" },`);
});

test("zigbase static_routes translates a trailing catch-all '*' to ZigBase's '**'", () => {
  const catchAll: Manifest = {
    ...m,
    dynamic: [{ pattern: "/app/admin/*", shell: "/app/admin/_shell.html" }],
  };
  const snippet = emitZigbase(catchAll).find((f) => f.name === "zigbase.static_routes.zig")!;
  expect(snippet.content).toContain(`.{ .match = "/app/admin/**", .serve = "/app/admin/_shell.html" },`);
  // never emit a bare terminal "*" (ZigBase's "*" means one-or-more, changing semantics)
  expect(snippet.content).not.toContain(`.match = "/app/admin/*"`);
});

// ── url_path_prefix: a site mounted under a host-chosen sub-path ────────────
// The manifest's route VALUES stay tree-relative (they describe a position
// inside the built output tree, which has no prefix directory in it); each
// emitter applies url_path_prefix according to ITS OWN semantics instead. See
// the Manifest.url_path_prefix doc comment and emitZigbase's doc comment for
// the full argument — these tests pin the concrete behavior it implies.

const mPrefixed: Manifest = { ...m, url_path_prefix: "/myrepo" };

test("nginx prefixes location selectors and try_files targets, not $uri", () => {
  const [file] = emitNginx(mPrefixed);
  expect(file.content).toContain(`location "/myrepo/app/" {`);
  expect(file.content).toContain(`try_files $uri $uri/ "/myrepo/app/index.html";`);
  expect(file.content).toContain(`location "/myrepo/app/club/" {`);
  expect(file.content).toContain(`try_files $uri "/myrepo/app/club/_shell.html" "/myrepo/app/index.html";`);
});

test("nginx never doubles the slash for a root-mounted SPA under a prefix", () => {
  // base "/" normally collapses to a single "/"; under a prefix that must
  // stay "/myrepo/", never "/myrepo//" (matches no request path) and never
  // the bare "//" the no-prefix guard exists to avoid.
  const root: Manifest = {
    ...m, base: "/", fallback: "/index.html", url_path_prefix: "/myrepo",
    dynamic: [{ pattern: "/:id", shell: "/_shell.html" }],
  };
  const [file] = emitNginx(root);
  expect(file.content).toContain(`location "/myrepo/" {`);
  expect(file.content).not.toContain(`/myrepo//`);
  expect(file.content).not.toContain(`location "//"`);
  expect(file.content).toContain(`try_files $uri "/myrepo/_shell.html" "/myrepo/index.html";`);
});

test("apache: RewriteBase carries the prefix; patterns stay unprefixed; targets become RewriteBase-relative", () => {
  const [file] = emitApache(mPrefixed);
  expect(file.content).toContain(`RewriteBase /myrepo/`);
  // RewriteRule PATTERNS must NOT be prefixed: Apache already strips the
  // containing directory's (now-prefixed) URL-path before a per-directory
  // .htaccess ever sees the request path — prefixing here would double-count it.
  expect(file.content).toContain(`RewriteRule ^app/club/.*$ app/club/_shell.html [L]`);
  expect(file.content).toContain(`RewriteRule ^app/.*$ app/index.html [L]`);
  expect(file.content).not.toContain(`^myrepo`);
  // Targets are relative-to-RewriteBase (no leading slash): an absolute
  // leading-slash target would bypass RewriteBase entirely and resolve from
  // the server root, missing the prefix.
  expect(file.content).not.toContain(` /app/club/_shell.html [L]`);
  expect(file.content).not.toContain(` /app/index.html [L]`);
});

test("apache header comment names the prefix and where the file mounts", () => {
  const [file] = emitApache(mPrefixed);
  expect(file.content).toContain(`mounted at URL prefix /myrepo`);
});

test("zigbase prefixes .match but leaves .serve tree-relative — the deliberate asymmetry", () => {
  const snippet = emitZigbase(mPrefixed).find((f) => f.name === "zigbase.static_routes.zig")!;
  expect(snippet.content).toContain(
    `.{ .match = "/myrepo/app/club/:id", .serve = "/app/club/_shell.html" },`,
  );
  expect(snippet.content).toContain(
    `.{ .match = "/myrepo/app/**", .serve = "/app/index.html" },`,
  );
  // ZigBase resolves .serve against the served root directory holding this
  // build's (unprefixed) output tree — prefixing it would point at a path
  // that does not exist.
  expect(snippet.content).not.toContain(`.serve = "/myrepo`);
});

test("zigbase snippet explains the prefix asymmetry, but only when a prefix is present", () => {
  const unprefixed = emitZigbase(m).find((f) => f.name === "zigbase.static_routes.zig")!;
  const prefixed = emitZigbase(mPrefixed).find((f) => f.name === "zigbase.static_routes.zig")!;
  expect(unprefixed.content).not.toContain("Mounted at URL prefix");
  expect(prefixed.content).toContain(`Mounted at URL prefix "/myrepo"`);
});

// The property that makes this change safe for every EXISTING site: both
// unprefixed spellings (the field absent, and "") must emit output
// byte-for-byte equal to today's, for all three emitters.

test("empty url_path_prefix emits byte-identical nginx output to an absent prefix", () => {
  const [file] = emitNginx({ ...m, url_path_prefix: "" });
  expect(file.content).toContain(`location "/app/" {`);
  expect(file.content).toContain(`try_files $uri $uri/ "/app/index.html";`);
  expect(file.content).toContain(`location "/app/club/" {`);
  expect(file.content).toContain(`try_files $uri "/app/club/_shell.html" "/app/index.html";`);
  expect(file.content).toBe(emitNginx(m)[0].content);
});

test("empty url_path_prefix emits byte-identical apache output to an absent prefix", () => {
  const [file] = emitApache({ ...m, url_path_prefix: "" });
  expect(file.content).not.toContain("RewriteBase");
  expect(file.content).toBe(emitApache(m)[0].content);
});

test("empty url_path_prefix emits byte-identical zigbase output to an absent prefix", () => {
  const withEmpty = emitZigbase({ ...m, url_path_prefix: "" }).find((f) => f.name === "zigbase.static_routes.zig")!;
  const withoutField = emitZigbase(m).find((f) => f.name === "zigbase.static_routes.zig")!;
  expect(withEmpty.content).toBe(withoutField.content);
});

test("assertSafeManifest rejects a malicious url_path_prefix, naming it", () => {
  expect(() => assertSafeManifest({ ...m, url_path_prefix: "/../etc" }))
    .toThrow(/manifest url_path_prefix .*".." segment/);
  expect(() => assertSafeManifest({ ...m, url_path_prefix: '/app"; evil' }))
    .toThrow(/manifest url_path_prefix .*is not a safe URL path/);
  // "" and absent are both valid (unprefixed) spellings — must not throw.
  expect(() => assertSafeManifest({ ...m, url_path_prefix: "" })).not.toThrow();
  expect(() => assertSafeManifest(m)).not.toThrow();
});

test("assertSafeManifest rejects a TRAILING-SLASH url_path_prefix", () => {
  // SAFE_PATH_RE alone accepts "/myrepo/" and "/", and both concatenate onto
  // leading-"/" route values into a doubled slash — `location "/myrepo//app/"`,
  // `.match = "//app/**"` — which matches no request path, so every deep link
  // 404s instead of the build failing. src/spa.zig normalizes and so cannot
  // produce these; the validator's whole job is to guard a manifest this build
  // did not write.
  expect(() => assertSafeManifest({ ...m, url_path_prefix: "/myrepo/" }))
    .toThrow(/must not end with "\/"/);
  expect(() => assertSafeManifest({ ...m, url_path_prefix: "/" }))
    .toThrow(/must not end with "\/"/);
  // The normalized form is still accepted.
  expect(() => assertSafeManifest({ ...m, url_path_prefix: "/myrepo" })).not.toThrow();
});

test("the nginx config states the mount the prefixed selectors assume", () => {
  // The selectors and try_files targets are REQUEST paths carrying the prefix,
  // but the files they name live in a tree with no prefix directory — so they
  // are only correct when the server maps <prefix>/… onto the built tree.
  // Nothing in the directives reveals that, and getting it wrong 404s every
  // deep link, so the header has to say it (as Apache's already did).
  const [file] = emitNginx(mPrefixed);
  expect(file.content).toContain("mounted at URL prefix /myrepo");
  expect(file.content).toMatch(/serve the built tree from <docroot>\/myrepo\//);
  // An unprefixed site has no such assumption to state.
  const [bare] = emitNginx(m);
  expect(bare.content).not.toContain("mounted at URL prefix");
});

test("every emitter validates url_path_prefix before interpolating", () => {
  const bad: Manifest = { ...m, url_path_prefix: '/myrepo"; evil' };
  expect(() => emitNginx(bad)).toThrow();
  expect(() => emitApache(bad)).toThrow();
  expect(() => emitZigbase(bad)).toThrow();
});

// ── Route values are validated + per-language encoded ───────────────────────
// These are CORRECTNESS defects, not an attack surface: every value comes from
// the site author's own .spa.tsx. But an honest author's legitimate route must
// not emit a rule that means something other than what they wrote.

test("apache escapes a literal '.' in a route dir — 'v1.0' must not match 'v1X0'", () => {
  const dotted: Manifest = {
    ...m,
    dynamic: [{ pattern: "/docs/v1.0/:page", shell: "/docs/v1.0/_shell.html" }],
  };
  const [file] = emitApache(dotted);
  expect(file.content).toContain(`RewriteRule ^docs/v1\\.0/.*$ /docs/v1.0/_shell.html [L]`);
  // The unescaped form would shadow every /docs/v1X0/… URL under the same docroot.
  expect(file.content).not.toContain(`^docs/v1.0/.*$`);
});

test("apache escapes a literal '.' in the namespace base too", () => {
  const [file] = emitApache({ ...m, base: "/v1.0", fallback: "/v1.0/index.html", dynamic: [] });
  expect(file.content).toContain(`RewriteRule ^v1\\.0/.*$ /v1.0/index.html [L]`);
});

// ── escapePcre: which characters are escaped, and which deliberately are not ──
// The emitter's output is PCRE (mod_rewrite compiles with PCRE2), NOT an
// ECMAScript RegExp, which is why this is `escapePcre` and not `RegExp.escape`.
// The negative half below is the load-bearing half: it is what keeps a deployed
// .htaccess readable, and it is what a future "just use RegExp.escape" would
// break. See the doc comment on escapePcre for the full argument.

test("escapePcre escapes every PCRE metacharacter, with a backslash", () => {
  for (const c of [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]) {
    expect(escapePcre(c)).toBe("\\" + c);
  }
  expect(escapePcre(".*+?^${}()|[]\\")).toBe("\\.\\*\\+\\?\\^\\$\\{\\}\\(\\)\\|\\[\\]\\\\");
});

test("escapePcre leaves the rest of the validated charset LITERAL", () => {
  // assertSafeManifest admits exactly A-Za-z0-9 . _ ~ - / (plus : and * in a
  // pattern). Of those, "." is the ONLY one that means anything in PCRE outside
  // a character class — "-" is a range metacharacter solely inside [...], and
  // "/" is a delimiter only in a regex LITERAL, which a config file has none of.
  expect(escapePcre("app/club")).toBe("app/club");
  expect(escapePcre("a-b_c~d/e")).toBe("a-b_c~d/e");
  expect(escapePcre("docs/v1.2")).toBe("docs/v1\\.2");
  expect(escapePcre("")).toBe("");
  // The divergence from RegExp.escape, stated as an assertion rather than a
  // comment so it cannot quietly stop being true: no hex-escaping, and in
  // particular no unconditional hex-escape of the LEADING character.
  expect(escapePcre("app")).not.toContain("\\x");
  expect(RegExp.escape("app")).toBe("\\x61pp");
});

// ── The validation net: is the emitted config actually correct PCRE? ─────────
// Nothing else in this repo checks that a generated nginx/Apache file parses or
// means what it should — the other coverage greps for literal strings, which
// cannot catch a pattern that is valid but matches the wrong thing. So: run the
// patterns we actually emit through a real Perl-compatible regex engine.
//
// `perl` is the engine PCRE is *compatible with*, and is present on both CI
// runner images (ubuntu-latest and macos-latest ship it in the base image). It
// is used instead of `grep -P` because BSD grep on macOS has no -P at all.
// If it is missing this test FAILS rather than skips — a silently-skipped
// validation net is not a net.

function perlMatches(pattern: string, subject: string): boolean {
  const r = Bun.spawnSync([
    "perl", "-e", 'exit(($ARGV[1] =~ /$ARGV[0]/) ? 0 : 1)', "--", pattern, subject,
  ]);
  // 0 = matched, 1 = did not match. Anything else (2+, or a signal) means perl
  // itself rejected the pattern — a malformed regex, which is exactly the class
  // of bug this test exists to catch, so surface it rather than reading it as
  // "no match".
  if (r.exitCode !== 0 && r.exitCode !== 1) {
    throw new Error(
      `perl failed on /${pattern}/ (exit ${r.exitCode}): ${r.stderr.toString().trim()}`,
    );
  }
  return r.exitCode === 0;
}

/** Every `RewriteRule <pattern> …` pattern in an emitted .htaccess. */
function rewritePatterns(htaccess: string): string[] {
  return [...htaccess.matchAll(/^RewriteRule (\S+) /gm)].map((x) => x[1]);
}

test("perl is reachable — the PCRE validation below is real, not silently skipped", () => {
  expect(perlMatches("^abc$", "abc")).toBe(true);
  expect(perlMatches("^abc$", "abd")).toBe(false);
});

test("emitted RewriteRule patterns are valid PCRE that match the right URLs", () => {
  const dotted: Manifest = {
    ...m,
    base: "/v1.0",
    fallback: "/v1.0/index.html",
    dynamic: [{ pattern: "/v1.0/docs/a-b~c/:page", shell: "/v1.0/docs/a-b~c/_shell.html" }],
  };
  const [file] = emitApache(dotted);
  const pats = rewritePatterns(file.content);
  expect(pats).toEqual(["^v1\\.0/docs/a-b~c/.*$", "^v1\\.0/.*$"]);

  // mod_rewrite matches the request path WITHOUT its leading slash.
  // The dynamic-dir rule: matches its own subtree...
  expect(perlMatches(pats[0], "v1.0/docs/a-b~c/intro")).toBe(true);
  // ...and NOT a URL where an unescaped "." would have matched any character.
  expect(perlMatches(pats[0], "v1X0/docs/a-b~c/intro")).toBe(false);
  // "-" and "~" are literal, so they match themselves and nothing else.
  expect(perlMatches(pats[0], "v1.0/docs/aXb~c/intro")).toBe(false);
  expect(perlMatches(pats[0], "v1.0/docs/a-bXc/intro")).toBe(false);
  // The namespace fallback rule.
  expect(perlMatches(pats[1], "v1.0/anything/deep")).toBe(true);
  expect(perlMatches(pats[1], "v1X0/anything/deep")).toBe(false);
  // It must not swallow a SIBLING namespace that merely shares a prefix.
  expect(perlMatches(pats[1], "v1.0-beta/page")).toBe(false);
});

test("RegExp.escape output would ALSO be accepted by PCRE — so this is a readability call, not a correctness one", () => {
  // Stated as a test so the justification in escapePcre's doc comment is
  // verified rather than asserted. The interesting case is hex-digit adjacency:
  // RegExp.escape("v1.0") is "\x761\.0" — if any engine read more than two hex
  // digits after \x, "\x761" would be U+0761 instead of "v" followed by "1".
  expect(RegExp.escape("v1.0")).toBe("\\x761\\.0");
  expect(perlMatches("^" + RegExp.escape("v1.0") + "/.*$", "v1.0/page")).toBe(true);
  expect(perlMatches("^" + RegExp.escape("v1.0") + "/.*$", "v1X0/page")).toBe(false);
  expect(perlMatches("^" + RegExp.escape("a-b~c") + "$", "a-b~c")).toBe(true);
  // Both spellings are correct PCRE; they differ only in what an operator reads.
  // That is the whole basis for choosing escapePcre — see its doc comment.
});

test("unescaped interpolation really would be wrong — the bug escapePcre prevents", () => {
  // The control for the tests above: without escaping, the "." in a legitimate
  // route like /docs/v1.0 is a PCRE wildcard and the rule captures /docs/v1X0.
  expect(perlMatches("^docs/v1.0/.*$", "docs/v1X0/page")).toBe(true);
  expect(perlMatches("^docs/v1\\.0/.*$", "docs/v1X0/page")).toBe(false);
});

test("nginx special-cases a root-mounted SPA — `location /`, never `location //`", () => {
  const root: Manifest = {
    ...m, base: "/", fallback: "/index.html",
    dynamic: [{ pattern: "/club/:id", shell: "/club/_shell.html" }],
  };
  const [file] = emitNginx(root);
  expect(file.content).toContain(`location "/" {`);
  // "//" matches no request path: deep links would 404 instead of reaching the shell.
  expect(file.content).not.toContain(`location "//"`);
});

test("nginx never emits `location //` for a root-level dynamic route either", () => {
  const rootDynamic: Manifest = {
    ...m, base: "/", fallback: "/index.html",
    dynamic: [{ pattern: "/:id", shell: "/_shell.html" }],
  };
  const [file] = emitNginx(rootDynamic);
  expect(file.content).not.toContain(`location "//"`);
  expect(file.content).toContain(`try_files $uri "/_shell.html" "/index.html";`);
});

test("assertSafeManifest rejects an unsafe route value, naming it", () => {
  // A value that would terminate the nginx token and inject a directive.
  expect(() => assertSafeManifest({ ...m, base: "/app; return 302 http://evil" }))
    .toThrow(/manifest base .*is not a safe URL path/);
  expect(() => assertSafeManifest({ ...m, fallback: "/app/index.html\nadd_header X 1" }))
    .toThrow(/manifest fallback/);
  expect(() => assertSafeManifest({ ...m, dynamic: [{ pattern: "/app/(a|b)/:id", shell: "/app/_shell.html" }] }))
    .toThrow(/dynamic route pattern/);
  expect(() => assertSafeManifest({ ...m, dynamic: [{ pattern: "/app/x/:id", shell: "/app/x/../../etc/passwd" }] }))
    .toThrow(/dynamic route shell .*".." segment/);
  expect(() => assertSafeManifest({ ...m, base: "app" })).toThrow(/is not a safe URL path/);
  // …and accepts the legitimate dotted route the Apache escaper exists for.
  expect(() => assertSafeManifest({
    ...m, dynamic: [{ pattern: "/docs/v1.0/:page", shell: "/docs/v1.0/_shell.html" }],
  })).not.toThrow();
});

test("every emitter validates before interpolating", () => {
  const bad: Manifest = { ...m, base: '/app"; evil' };
  expect(() => emitNginx(bad)).toThrow();
  expect(() => emitApache(bad)).toThrow();
  expect(() => emitZigbase(bad)).toThrow();
});

test("zigStringLiteral escapes quotes, backslashes and control bytes", () => {
  expect(zigStringLiteral("/app/club")).toBe(`"/app/club"`);
  expect(zigStringLiteral('a"b')).toBe(`"a\\"b"`);
  expect(zigStringLiteral("a\\b")).toBe(`"a\\\\b"`);
  expect(zigStringLiteral("a\nb")).toBe(`"a\\x0ab"`);
  expect(zigStringLiteral("a\u{1F600}b")).toBe(`"a\\u{1f600}b"`);
});

// ── Strict-CSP inline-script hashing ────────────────────────────────────────

const IMPORTMAP = `{"imports":{"@z/runtime":"/zigapagos-runtime.js"}}`;
const BOOTSTRAP = `import*as m from"/spa/app.js";import{mountSpa}from"@z/runtime";mountSpa(m.default,"#z-spa-root",m);`;

// A realistic page: importmap (inline) + external runtime + inline module boot +
// a json data block (data-z-props) whose value even contains an ESCAPED nested
// </script> (data-z-slots) — the browser treats that as content, not markup.
const PAGE = [
  `<!DOCTYPE html><html><head>`,
  `<script type="importmap">${IMPORTMAP}</script>`,
  `<script type="module" src="/zigapagos-runtime.js"></script>`,
  `<script type="module">${BOOTSTRAP}</script>`,
  `</head><body>`,
  `<script type="application/json" data-z-props="z-0">{"headline":"Hi"}</script>`,
  `<script type="application/json" data-z-slots="z-1">{"default":"<p>x<\\/p><script type=\\"application/json\\">{}<\\/script>"}</script>`,
  `</body></html>`,
].join("");

// The SPA shell's baked-flag-defaults snapshot is a JSON data
// block too — inert, never executed, so it must contribute NO script-src hash.
const FLAGS_BLOCK = `<script type="application/json" data-z-flags>{"flags":{"bookAsGuest":true},"experiments":{}}</script>`;

// A CSP hash-source token: the base64 digest wrapped in the single quotes the
// grammar requires (an unquoted `sha256-…` is parsed as a host source).
const b64 = (s: string) => "'sha256-" + createHash("sha256").update(s, "utf8").digest("base64") + "'";

/** The `script-src …;` directive text (the XSS-critical one that must stay strict). */
const scriptSrcOf = (csp: string) => csp.match(/script-src[^;]*/)![0];

test("scanInlineScriptHashes returns EXACTLY the two inline hashes (json + external excluded)", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  expect(hashes).toEqual([b64(IMPORTMAP), b64(BOOTSTRAP)].sort());
  expect(hashes.length).toBe(2);
});

test("the data-z-flags snapshot is a data block — no script-src hash needed or emitted", () => {
  const withFlags = PAGE.replace("</head>", FLAGS_BLOCK + "</head>");
  expect(scanInlineScriptHashes([withFlags])).toEqual(scanInlineScriptHashes([PAGE]));
});

test("a scanned hash equals an independently-computed sha256-base64 of the exact content", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  const independent = "'sha256-" + createHash("sha256").update(BOOTSTRAP, "utf8").digest("base64") + "'";
  expect(hashes).toContain(independent);
});

test("hash tokens are single-quoted (unquoted is parsed as a host source and ignored)", () => {
  for (const hsh of scanInlineScriptHashes([PAGE])) {
    expect(hsh.startsWith("'sha256-")).toBe(true);
    expect(hsh.endsWith("'")).toBe(true);
  }
});

test("hashes are deduped and sorted across multiple pages", () => {
  // Two SPA shells share the same importmap + bootstrap → still only two hashes.
  const other = `<html><head><script type="importmap">${IMPORTMAP}</script>` +
    `<script type="module">${BOOTSTRAP}</script></head></html>`;
  const hashes = scanInlineScriptHashes([PAGE, other]);
  expect(hashes).toEqual([b64(IMPORTMAP), b64(BOOTSTRAP)].sort());
  const sorted = [...hashes].sort();
  expect(hashes).toEqual(sorted); // stable/sorted output
});

test("nginx CSP snippet has script-src 'self' + both hashes and NO unsafe-inline in script-src", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  const file = emitCsp(hashes, "nginx");
  expect(file.name).toBe("csp.nginx.conf");
  expect(file.content).toContain(`script-src 'self' ${hashes[0]} ${hashes[1]}`);
  expect(file.content).toContain("add_header Content-Security-Policy");
  expect(file.content).toContain("always;");
  // script-src stays strict; style-src-attr is the only directive carrying
  // unsafe-inline (the framework's inline style ATTRIBUTES) — style-src-elem
  // (<style> elements) is just as strict as script-src.
  expect(scriptSrcOf(file.content)).not.toContain("unsafe-inline");
});

test("cspHeaderValue is a strict baseline: script-src AND style-src-elem have no unsafe-inline; only style-src-attr is lenient", () => {
  const v = cspHeaderValue(scanInlineScriptHashes([PAGE]));
  expect(v).toContain("default-src 'self'");
  expect(v).toContain("script-src 'self' 'sha256-");
  expect(v).toContain("object-src 'none'");
  expect(v).toContain("base-uri 'self'");
  expect(scriptSrcOf(v)).not.toContain("unsafe-inline"); // script-src is strict
  expect(v).toContain("style-src-elem 'self'"); // <style> elements: strict, no unsafe-inline
  expect(v).toContain("style-src-attr 'unsafe-inline'"); // framework inline style ATTRIBUTES only
});

test("apache + zigbase CSP artifacts carry the same header value, script-src strict", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  const value = cspHeaderValue(hashes);
  const files = emitAllCsp(hashes);
  expect(files.map((f) => f.name).sort()).toEqual(
    ["csp.apache.conf", "csp.nginx.conf", "csp.zigbase.txt"],
  );
  const apache = files.find((f) => f.name === "csp.apache.conf")!;
  const zigbase = files.find((f) => f.name === "csp.zigbase.txt")!;
  expect(apache.content).toContain(`Header set Content-Security-Policy "${value}"`);
  expect(zigbase.content).toContain(`Content-Security-Policy: ${value}`);
  expect(scriptSrcOf(apache.content)).not.toContain("unsafe-inline");
  expect(scriptSrcOf(zigbase.content)).not.toContain("unsafe-inline");
});

// ── CSP must include spa.head external origins ──────────────────────────────
// A `spa.head` like
//   [{ rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "anonymous" },
//    { rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Inter" }]
// renders into every shell's <head> as <link> tags. The emitted CSP must allow
// those origins or the deployed conf blocks the fonts the build itself linked.
// Rule: every external origin referenced by a <link> href in the built HTML is
// unioned into BOTH style-src-elem and font-src (simple + predictable; a
// stylesheet origin and the font origin it pulls from both end up allowed).

// Rendered exactly like src/spa.zig's renderHeadLinks output (attribute values
// HTML-escaped, so a query "&" appears as "&amp;").
const FONT_PAGE = [
  `<!DOCTYPE html><html><head>`,
  `<script type="importmap">${IMPORTMAP}</script>`,
  `<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous">`,
  `<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter&amp;display=swap">`,
  `<link rel="stylesheet" href="/site.css">`,
  `<link rel="modulepreload" href="/spa/app.js">`,
  `<script type="module">${BOOTSTRAP}</script>`,
  `</head><body></body></html>`,
].join("");

const styleSrcOf = (csp: string) => csp.match(/style-src-elem[^;]*/)![0];

test("scanExternalLinkOrigins returns the sorted, deduped external <link> origins (local hrefs excluded)", () => {
  const origins = scanExternalLinkOrigins([FONT_PAGE]);
  expect(origins).toEqual(["https://fonts.googleapis.com", "https://fonts.gstatic.com"]);
});

test("scanExternalLinkOrigins dedupes across pages and strips path/query (incl. HTML-escaped &amp;)", () => {
  const other = `<html><head><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Other&amp;display=swap"></head></html>`;
  const origins = scanExternalLinkOrigins([FONT_PAGE, other, FONT_PAGE]);
  expect(origins).toEqual(["https://fonts.googleapis.com", "https://fonts.gstatic.com"]);
});

test("scanExternalLinkOrigins folds protocol-relative hrefs in, defaulting the scheme to https", () => {
  // docs/spa.md promises protocol-relative (`//host`) origins are folded into
  // the CSP like absolute ones; a strict-CSP deployment is https, so that is
  // the scheme the browser resolves them to.
  const page = `<html><head>` +
    `<link rel="stylesheet" href="//fonts.googleapis.com/css2?family=Inter&amp;display=swap">` +
    `<link rel="preconnect" href="//fonts.gstatic.com">` +
    `<link rel="stylesheet" href="/local.css">` +
    `</head></html>`;
  expect(scanExternalLinkOrigins([page])).toEqual([
    "https://fonts.googleapis.com",
    "https://fonts.gstatic.com",
  ]);
  // …and dedupes against the same origins spelled absolutely.
  expect(scanExternalLinkOrigins([page, FONT_PAGE])).toEqual([
    "https://fonts.googleapis.com",
    "https://fonts.gstatic.com",
  ]);
});

test("scanExternalLinkOrigins keeps an explicit port and ignores non-link tags and root-relative hrefs", () => {
  const page = `<html><head>` +
    `<link rel="stylesheet" href="https://cdn.example.com:8443/x.css">` +
    `<a href="https://not-a-link-tag.example.com/">x</a>` +
    `<link rel="stylesheet" href="/local.css">` +
    `</head></html>`;
  expect(scanExternalLinkOrigins([page])).toEqual(["https://cdn.example.com:8443"]);
});

test("cspHeaderValue unions external link origins into style-src-elem AND font-src (never style-src-attr)", () => {
  const hashes = scanInlineScriptHashes([FONT_PAGE]);
  const origins = scanExternalLinkOrigins([FONT_PAGE]);
  const v = cspHeaderValue(hashes, origins);
  expect(styleSrcOf(v)).toBe(
    "style-src-elem 'self' https://fonts.googleapis.com https://fonts.gstatic.com",
  );
  expect(v).toContain(
    "font-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com",
  );
  // script-src stays strict: origins are NOT added there.
  expect(scriptSrcOf(v)).not.toContain("fonts.");
  // Nor into style-src-attr, which carries only the fixed 'unsafe-inline' grant.
  expect(v).toContain("style-src-attr 'unsafe-inline'");
  expect(v).not.toContain("style-src-attr 'unsafe-inline' https://");
});

test("cspHeaderValue without external origins or style hashes is byte-identical across the linkOrigins/styleHashes defaults (no font-src)", () => {
  // Byte-identity with the OLD pre-split value is intentionally broken by this
  // change (issue #130 drops the blanket style-src) — what still must hold is
  // that omitting the optional params is identical to passing empty arrays.
  const hashes = scanInlineScriptHashes([PAGE]);
  expect(cspHeaderValue(hashes, [])).toBe(cspHeaderValue(hashes));
  expect(cspHeaderValue(hashes, [], [])).toBe(cspHeaderValue(hashes));
  expect(cspHeaderValue(hashes)).not.toContain("font-src");
  expect(styleSrcOf(cspHeaderValue(hashes))).toBe("style-src-elem 'self'");
});

test("all three emitted CSP flavors carry the head origins (nginx/apache/zigbase) and the style-src-attr grant", () => {
  const hashes = scanInlineScriptHashes([FONT_PAGE]);
  const origins = scanExternalLinkOrigins([FONT_PAGE]);
  const value = cspHeaderValue(hashes, origins);
  for (const f of emitAllCsp(hashes, origins)) {
    expect(f.content).toContain(value);
    expect(f.content).toContain("font-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com");
    expect(f.content).toContain("style-src-attr 'unsafe-inline'");
  }
  const nginx = emitCsp(hashes, "nginx", origins);
  expect(styleSrcOf(nginx.content)).toContain("https://fonts.googleapis.com");
});

test("no-type inline script IS hashed; application/json is NOT", () => {
  const classic = `<html><script>console.log(1)</script>` +
    `<script type="application/json">{"a":1}</script></html>`;
  const hashes = scanInlineScriptHashes([classic]);
  expect(hashes).toEqual([b64("console.log(1)")]);
});


// ── Cache-Control host-config artifacts (issue #133) ────────────────────────
// Astro's route-caching / CDN-header providers are an SSR feature that
// doesn't fit zigapagos, but their static-site shadow is worth taking:
// fingerprinted site assets (asset_fingerprint) and content-hashed SPA
// lazy-route chunks are already safe for immutable caching, and the
// host-config emitters already write routing rules per target. This follows
// the exact CSP precedent — three new site-wide, operator-merged artifacts.

const mWithChunks: Manifest = {
  ...m,
  chunks: { "/app/heavy/": "/spa/Heavy-abc123.js" },
};

test("nginx cache artifact: map block + exact constant values", () => {
  const file = emitCache("nginx", []);
  expect(file.name).toBe("cache.nginx.conf");
  expect(file.content).toContain("map $uri $zigapagos_cache_control");
  expect(file.content).toContain(`"${IMMUTABLE_CACHE_CONTROL}"`);
  expect(file.content).toContain(`"${REVALIDATE_CACHE_CONTROL}"`);
});

// The BASELINE is the half of the issue's ask that the fingerprint pattern
// cannot cover. /spa/<name>.js, /spa/<name>-runtime.js, /islands/*.js and
// /zigapagos-runtime.js are all at STABLE paths with content that changes
// every deploy and no hash in the name, so leaving them header-less hands them
// to heuristic (or CDN-default) caching — fresh HTML paired with a stale
// bundle. Both emitters must therefore name a revalidating DEFAULT, not "".
test("nginx baseline: an unmatched stable path (the SPA entry bundle) revalidates, it is not left header-less", () => {
  const file = emitCache("nginx", []);
  expect(file.content).toContain(`default "${REVALIDATE_CACHE_CONTROL}";`);
  expect(file.content).not.toContain(`default "";`);
  // The nginx map's `default` is position-independent, so this is the whole
  // rule for /spa/app.js: no other line here can match it.
  const re = new RegExp(FINGERPRINT_SUFFIX_PATTERN);
  expect(re.test("/spa/app.js")).toBe(false);
});

test("apache baseline: a catch-all no-cache FilesMatch is emitted FIRST, so the immutable stanzas below still win", () => {
  const file = emitCache("apache", []);
  const catchAllIdx = file.content.indexOf(`<FilesMatch ".">`);
  const immutableIdx = file.content.indexOf(IMMUTABLE_CACHE_CONTROL);
  expect(catchAllIdx).toBeGreaterThan(-1);
  // Apache is last-Header-set-wins, so a baseline that came AFTER the
  // fingerprint stanza would silently un-do immutable caching.
  expect(catchAllIdx).toBeLessThan(immutableIdx);
});

test("zigbase advisory names the stable-path baseline too, not just the two matched shapes", () => {
  const file = emitCache("zigbase", []);
  expect(file.content).toContain("everything else");
  expect(file.content).toContain("/zigapagos-runtime.js");
});

test("nginx cache ORDER: \\.html$ no-cache appears before the fingerprint regex (stable beats immutable, first-match-wins)", () => {
  const file = emitCache("nginx", []);
  const htmlIdx = file.content.indexOf(String.raw`~\.html$`);
  const fingerprintIdx = file.content.indexOf(FINGERPRINT_SUFFIX_PATTERN);
  expect(htmlIdx).toBeGreaterThan(-1);
  expect(fingerprintIdx).toBeGreaterThan(-1);
  expect(htmlIdx).toBeLessThan(fingerprintIdx);
});

test("apache cache ORDER: immutable <FilesMatch> appears before the \\.html$ no-cache one (last Header set wins)", () => {
  const file = emitCache("apache", []);
  const immutableIdx = file.content.indexOf(IMMUTABLE_CACHE_CONTROL);
  const htmlIdx = file.content.indexOf(String.raw`\.html$`);
  expect(immutableIdx).toBeGreaterThan(-1);
  expect(htmlIdx).toBeGreaterThan(-1);
  expect(immutableIdx).toBeLessThan(htmlIdx);
});

test("chunk exact-listing: nginx gets a quoted exact map entry, apache gets a basename FilesMatch alternation", () => {
  const chunkPaths = collectChunkPaths([mWithChunks]);
  expect(chunkPaths).toEqual(["/spa/Heavy-abc123.js"]);

  const nginx = emitCache("nginx", chunkPaths);
  expect(nginx.content).toContain(`"/spa/Heavy-abc123.js"`);

  const apache = emitCache("apache", chunkPaths);
  // "." in the chunk basename is escapePcre'd, same discipline as route values.
  expect(apache.content).toContain("^(Heavy-abc123\\.js)$");
});

test("collectChunkPaths unions across manifests, dedupes+sorts, and tolerates a manifest with no chunks field", () => {
  const a: Manifest = { ...m, chunks: { "/x/": "/spa/B-2.js", "/y/": "/spa/A-1.js" } };
  const b: Manifest = { ...m, chunks: { "/x/": "/spa/B-2.js" } }; // duplicate value
  const c: Manifest = { ...m }; // no chunks field at all — back-compat
  expect(collectChunkPaths([a, b, c])).toEqual(["/spa/A-1.js", "/spa/B-2.js"]);
  expect(() => collectChunkPaths([c])).not.toThrow();
  expect(collectChunkPaths([c])).toEqual([]);
});

test("collectChunkPaths rejects an unsafe chunk value, naming it, and accepts '+' in a basename", () => {
  expect(() => collectChunkPaths([{ ...m, chunks: { "/x/": "/spa/evil path.js" } }]))
    .toThrow(/"\/spa\/evil path\.js"/);
  expect(() => collectChunkPaths([{ ...m, chunks: { "/x/": '/spa/"evil.js' } }]))
    .toThrow(/is not a safe URL path/);
  expect(() => collectChunkPaths([{ ...m, chunks: { "/x/": "/spa/../../etc/passwd" } }]))
    .toThrow(/segment/);
  // Bun legitimately names some chunks with a "+" in the basename (module
  // names like "useA+B" — see findRouteChunk's doc comment in bundle-island.ts).
  expect(() => collectChunkPaths([{ ...m, chunks: { "/x/": "/spa/foo+bar-abc123.js" } }])).not.toThrow();
  expect(collectChunkPaths([{ ...m, chunks: { "/x/": "/spa/foo+bar-abc123.js" } }]))
    .toEqual(["/spa/foo+bar-abc123.js"]);
});

test("zigbase cache artifact is advisory: both header values, the concrete chunk path, and warns against the global knob", () => {
  const chunkPaths = collectChunkPaths([mWithChunks]);
  const file = emitCache("zigbase", chunkPaths);
  expect(file.name).toBe("cache.zigbase.txt");
  expect(file.content).toContain(IMMUTABLE_CACHE_CONTROL);
  expect(file.content).toContain(REVALIDATE_CACHE_CONTROL);
  expect(file.content).toContain("/spa/Heavy-abc123.js");
  expect(file.content).toContain("ZIGBASE_STATIC_CACHE_CONTROL");
  expect(file.content.toLowerCase()).toContain("do not set it");
});

test("emitAllCache writes all three targets, and works with an empty chunk set (island-only sites)", () => {
  const files = emitAllCache([]);
  expect(files.map((f) => f.name).sort()).toEqual(
    ["cache.apache.conf", "cache.nginx.conf", "cache.zigbase.txt"],
  );
});

// ── FINGERPRINT_SUFFIX_PATTERN: the asset_fingerprint name-shape heuristic ──
// src/fingerprint.zig's nameFromDigest: "<stem>.<8 lowercase hex>.<ext>",
// extension-less files get the hash appended ("CNAME.a1b2c3d4").

test("FINGERPRINT_SUFFIX_PATTERN matches the fingerprinted name shape and nothing else", () => {
  const re = new RegExp(FINGERPRINT_SUFFIX_PATTERN);
  expect(re.test("style.a1b2c3d4.css")).toBe(true);
  expect(re.test("CNAME.a1b2c3d4")).toBe(true);
  expect(re.test("style.css")).toBe(false);
  expect(re.test("app-runtime.js")).toBe(false);
  expect(re.test("index.html")).toBe(false);
  // The stable-path bundles the baseline exists for: none of them may drift
  // into the immutable rule on a name that merely looks hex-ish.
  expect(re.test("app.js")).toBe(false);
  expect(re.test("app-runtime.js")).toBe(false);
  expect(re.test("Heavy-abc123.js")).toBe(false);
  // Uppercase hex and a 7- or 9-digit run are NOT nameFromDigest output.
  expect(re.test("style.A1B2C3D4.css")).toBe(false);
  expect(re.test("style.a1b2c3d.css")).toBe(false);
  expect(re.test("style.a1b2c3d4e.css")).toBe(false);
});

// The pattern is spliced VERBATIM into an Apache <FilesMatch>, which mod_headers
// compiles with PCRE2 — so it has to be checked by the same real engine the
// RewriteRule patterns above are, not only by ECMAScript's. (A JS-only check
// would have accepted a pattern PCRE rejects outright.)
test("the emitted <FilesMatch> patterns are valid PCRE that match the right BASENAMES", () => {
  const chunkPaths = collectChunkPaths([mWithChunks]);
  const pats = [...emitCache("apache", chunkPaths).content.matchAll(/^\s*<FilesMatch "(.*)">$/gm)]
    .map((x) => x[1]);
  // catch-all baseline, fingerprint, chunk alternation, .html, routing-manifest
  expect(pats.length).toBe(5);

  // FilesMatch is applied to the BASENAME, unanchored.
  expect(perlMatches(pats[0], "app.js")).toBe(true); // the baseline catches everything
  expect(perlMatches(pats[1], "style.a1b2c3d4.css")).toBe(true);
  expect(perlMatches(pats[1], "app.js")).toBe(false);
  expect(perlMatches(pats[2], "Heavy-abc123.js")).toBe(true);
  // The escaped "." in the chunk basename must not match any character.
  expect(perlMatches(pats[2], "Heavy-abc123Xjs")).toBe(false);
  // ...and the alternation is anchored, so a longer name is not a chunk.
  expect(perlMatches(pats[2], "xHeavy-abc123.js")).toBe(false);
  expect(perlMatches(pats[3], "index.html")).toBe(true);
  expect(perlMatches(pats[3], "indexXhtml")).toBe(false);
  expect(perlMatches(pats[4], "routing-manifest.json")).toBe(true);
});

// ── style-src-elem / style-src-attr split (issue #130) ──────────────────────
// The blanket `style-src 'self' 'unsafe-inline'` granted inline-style-ELEMENT
// injection sitewide to cover something narrower: inline style ATTRIBUTES
// (`display:contents` on island slot wrappers), which hashes cannot reach.
// These tests are the regression pin for that split; each was run against the
// unmodified (pre-#130) emitter and confirmed to FAIL there.

test("unsafe-inline appears in style-src-attr and NOWHERE else", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  const v = cspHeaderValue(hashes);
  const directives = v.split("; ");
  const withUnsafeInline = directives.filter((d) => d.includes("'unsafe-inline'"));
  expect(withUnsafeInline).toEqual(["style-src-attr 'unsafe-inline'"]);
});

test("no blanket style-src directive is emitted", () => {
  const hashes = scanInlineScriptHashes([PAGE]);
  const v = cspHeaderValue(hashes);
  const directives = v.split("; ");
  // Space after "style-src" so this does not accidentally match
  // "style-src-elem"/"style-src-attr", which legitimately start with the same prefix.
  expect(directives.some((d) => d.startsWith("style-src "))).toBe(false);
});

test("inline <style> ELEMENTS are hashed into style-src-elem, independent of script-src", () => {
  const STYLE_CONTENT = "h1{color:red}";
  const page = `<html><head><style>${STYLE_CONTENT}</style></head><body></body></html>`;
  const styleHashes = scanInlineStyleHashes([page]);
  const independent = "'sha256-" + createHash("sha256").update(STYLE_CONTENT, "utf8").digest("base64") + "'";
  expect(styleHashes).toEqual([independent]);

  const hashes = scanInlineScriptHashes([page]); // no <script> on this page
  const v = cspHeaderValue(hashes, [], styleHashes);
  expect(styleSrcOf(v)).toBe(`style-src-elem 'self' ${independent}`);
  expect(scriptSrcOf(v)).not.toContain(independent); // never leaks into script-src
});

test("scanInlineStyleHashes dedupes + sorts across pages; a style ATTRIBUTE contributes nothing; an empty page yields []", () => {
  const a = `<html><head><style>h1{color:red}</style></head><body></body></html>`;
  const b = `<html><head><style>h1{color:red}</style><style>p{margin:0}</style></head></html>`;
  const withAttrOnly = `<div style="display:contents">x</div>`; // attribute, not an element
  expect(scanInlineStyleHashes([a, b])).toEqual(
    [...new Set([...scanInlineStyleHashes([a]), ...scanInlineStyleHashes([b])])].sort(),
  );
  expect(scanInlineStyleHashes([a, b]).length).toBe(2); // deduped: "h1{color:red}" shared
  expect(scanInlineStyleHashes([withAttrOnly])).toEqual([]);
  expect(scanInlineStyleHashes([])).toEqual([]);
  expect(scanInlineStyleHashes(["<html></html>"])).toEqual([]);
  // An empty style-hash set still yields a well-formed, strict style-src-elem.
  expect(cspHeaderValue([], [], [])).toContain("style-src-elem 'self'");
});

// ── Tokenizer fidelity of the hash scanners ────────────────────────────────
// A hash allow-list that disagrees with the browser's tokenizer is worse than
// no allow-list: the bogus match ALSO consumes forward past the real element,
// so the header both permits text that is not markup and omits the hash of
// markup that is. examples/tsx-site/layouts/index.shtml carries a comment that
// names the tags below it precisely so the e2e run exercises this too.

test("a <style>/<script> named inside an HTML COMMENT is text: no hash, and the real element that follows still gets one", () => {
  const page = [
    `<html><head>`,
    `<!-- the <style> block below is inline on purpose; so is the <script> -->`,
    `<style>h1{color:red}</style>`,
    `<script type="module">boot()</script>`,
    `</head><body></body></html>`,
  ].join("");
  // Naive regexes would open at the mention inside the comment and run to the
  // real close tag, hashing "-->…<style>h1{color:red}" and losing the true one.
  expect(scanInlineStyleHashes([page])).toEqual([b64("h1{color:red}")]);
  expect(scanInlineScriptHashes([page])).toEqual([b64("boot()")]);
});

test("a <style> inside a JSON data block is CONTENT, not an element (data-z-slots escapes only `</`)", () => {
  // Exactly the shape src/islands/pass.zig emits: slot HTML with `</` escaped to
  // `<\/`, so the OPEN tag survives literally inside the JSON string.
  const page = [
    `<html><body>`,
    `<div><style>h1{color:red}</style></div>`,
    `<script type="application/json" data-z-slots="z-island-0">`,
    `{"default":"<style>evil{}<\\/style>"}`,
    `</script>`,
    `<style>p{margin:0}</style>`,
    `</body></html>`,
  ].join("");
  // The JSON block contributes nothing, and — the part a naive scan gets wrong —
  // the <style> AFTER it is still hashed rather than swallowed.
  expect(scanInlineStyleHashes([page])).toEqual(
    [b64("h1{color:red}"), b64("p{margin:0}")].sort(),
  );
});

test("an unterminated comment or raw-text element stops the scan instead of guessing", () => {
  expect(scanInlineStyleHashes([`<style>a{}</style><!-- <style>b{}</style>`])).toEqual([b64("a{}")]);
  expect(scanInlineStyleHashes([`<style>a{}</style><style>never closed`])).toEqual([b64("a{}")]);
  expect(scanInlineScriptHashes([`<script>a()</script><script>never closed`])).toEqual([b64("a()")]);
});
