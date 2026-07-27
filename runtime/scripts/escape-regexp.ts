/**
 * Escape regex metacharacters so a literal string can be spliced into a
 * `RegExp` source (or an Apache `RewriteRule` pattern) and match itself.
 *
 * Build-time only. Four modules had a byte-identical private copy of this —
 * `emit-host-config.ts`, `lint-island-imports.ts`, `react-alias.ts` and
 * `sidecar/bundle-island.ts` — with two of them carrying a comment explaining
 * that the others' copies were module-private and therefore unimportable. This
 * module is that missing import.
 *
 * ## Why not `RegExp.escape`
 *
 * `RegExp.escape` (ES2025) is NOT a drop-in replacement, and swapping to it
 * would be a behaviour change, not a cleanup. It is specified to produce a
 * string safe in *any* regex position, which it achieves by escaping far more
 * than the metacharacter set: it `\x`-encodes a leading identifier character
 * and every character in its punctuator set, so
 *
 *     RegExp.escape("a-b.c/d$e")  === "\\x61\\x2db\\.c\\/d\\$e"
 *     escapeRegExp("a-b.c/d$e")   === "a-b\\.c/d\\$e"
 *
 * Both match the same input, but they are different STRINGS — and
 * `emit-host-config.ts` interpolates its result into generated `nginx`/Apache
 * config files and a Zig `.static_routes` snippet that ship as build artifacts.
 * Changing the spelling changes those files for every consumer, for no
 * behavioural gain, so this helper deliberately keeps the narrow set below.
 *
 * ## What is and is not escaped
 *
 * Escaped — the 14 characters that are metacharacters in a JS regex:
 * `.` `*` `+` `?` `^` `$` `{` `}` `(` `)` `|` `[` `]` `\`
 *
 * NOT escaped, on purpose — characters that are literal outside a character
 * class and would only add noise to a generated config: `-` (a range only
 * inside `[...]`), `/` (a delimiter only in a regex *literal*; every caller
 * builds via the `RegExp` constructor from a string), and `,` `:` `!` `=` `<`
 * `>` `#` `&` `~` `_` and whitespace.
 *
 * `escape-regexp.test.ts` pins both halves of that asymmetry; the negative half
 * is what stops a future "just use `RegExp.escape`" from landing silently.
 */
export function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
