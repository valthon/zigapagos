import { expect, test } from "bun:test";
import { escapeRegExp } from "./escape-regexp.ts";

// The exact output spelling is load-bearing, not just the matching behaviour:
// emit-host-config.ts interpolates the result into generated Apache
// `RewriteRule` patterns that ship as build artifacts, so a change here changes
// every consumer's `.htaccess`. These tests therefore assert on STRINGS, and
// the negative half is as load-bearing as the positive half — it is what
// distinguishes this helper from `RegExp.escape` (see escape-regexp.ts).

test("escapes every JS regex metacharacter, and only with a backslash", () => {
  // The 14 characters the character class covers, each on its own so a
  // regression names the offender rather than failing on one long blob.
  for (const c of [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]) {
    expect(escapeRegExp(c)).toBe("\\" + c);
  }
  // ...and all of them together, adjacent, with no reordering or collapsing.
  expect(escapeRegExp(".*+?^${}()|[]\\")).toBe("\\.\\*\\+\\?\\^\\$\\{\\}\\(\\)\\|\\[\\]\\\\");
});

test("leaves non-metacharacters LITERAL — the divergence from RegExp.escape", () => {
  // `-` is only special inside a character class; `/` only in a regex LITERAL,
  // and every caller builds via `new RegExp(string)`. RegExp.escape encodes
  // both (and hex-escapes a leading identifier char); we deliberately do not,
  // because these land verbatim in generated nginx/Apache/Zig config.
  expect(escapeRegExp("a-b.c/d$e")).toBe("a-b\\.c/d\\$e");
  // Nothing at all to escape => the input, unchanged and un-encoded. A
  // RegExp.escape-based implementation would return "\\x61pp/club" here.
  expect(escapeRegExp("app/club")).toBe("app/club");
  // The rest of the punctuation that is literal outside a character class.
  expect(escapeRegExp("a,b:c!d=e<f>g#h&i~j_k l")).toBe("a,b:c!d=e<f>g#h&i~j_k l");
  expect(escapeRegExp("")).toBe("");
});

test("the escaped string matches its input literally, and nothing else", () => {
  // The property the callers actually rely on: a path with a "." must not let
  // that "." match an arbitrary character (the "/docs/v1.0/:page" footgun
  // emit-host-config.ts's apache emitter is commented against).
  const re = new RegExp("^" + escapeRegExp("docs/v1.0") + "/.*$");
  expect(re.test("docs/v1.0/intro")).toBe(true);
  expect(re.test("docs/v1X0/intro")).toBe(false);
  // `$&` in the replacement is the MATCH, not a literal: a "$" in the input
  // must survive as one escaped "$", not expand into anything.
  expect(new RegExp("^" + escapeRegExp("a$b") + "$").test("a$b")).toBe(true);
  // A backslash in the input must be escaped, not consumed — an unescaped one
  // would swallow the following character in the constructed pattern.
  expect(new RegExp("^" + escapeRegExp("a\\b") + "$").test("a\\b")).toBe(true);
  expect(new RegExp("^" + escapeRegExp("a\\b") + "$").test("ab")).toBe(false);
});
