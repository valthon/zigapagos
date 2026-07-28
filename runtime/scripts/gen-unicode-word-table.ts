// Generates src/heading_slugs_table.zig — the Unicode letter/number range
// table `heading_slugs.zig`'s slugifier uses to decide which codepoints
// survive GitHub-compatible heading-anchor slugification (see issue #29).
//
// Regenerate with:
//
//     bun runtime/scripts/gen-unicode-word-table.ts
//
// (run from the repo root; needs `cd runtime && bun install --frozen-lockfile`
// once in a fresh worktree). The script overwrites
// src/heading_slugs_table.zig in place and runs `zig fmt` on it so the
// checked-in file is always fmt-clean.
//
// Method: enumerate every Unicode scalar value 0..0x10FFFF (skipping the
// surrogate range D800-DFFF, which holds no scalar values and therefore no
// codepoints a UTF-8 decoder can ever produce), test JS's `/[\p{L}\p{N}]/u`
// against each one, and coalesce consecutive matches into closed
// [start, end] ranges. `\p{L}` / `\p{N}` are General_Category Letter/Number,
// the same two top-level categories GitHub's own heading-anchor slugifier
// (html-pipeline's `unicode_alpha_regex`/`unicode_common_regex`) keeps.
//
// This table therefore tracks the Unicode Character Database version bundled
// with whatever Bun/V8 build ran this script (see `bun --version`), which is
// an APPROXIMATION of GitHub's own classification, not a guaranteed
// byte-for-byte match against GitHub's ICU version — the two only diverge at
// the margins of whatever codepoints a recent Unicode release added or
// reclassified, which is not expected to matter for real-world heading text.
// Zig's standard library ships no Unicode category data, which is why this
// table is generated from a JS engine rather than computed at comptime.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const OUT_PATH = join(REPO_ROOT, "src", "heading_slugs_table.zig");

const SURROGATE_LO = 0xd800;
const SURROGATE_HI = 0xdfff;
const MAX_CODEPOINT = 0x10ffff;

const isWordChar = /[\p{L}\p{N}]/u;

function matches(cp: number): boolean {
  return isWordChar.test(String.fromCodePoint(cp));
}

const ranges: [number, number][] = [];
let rangeStart: number | null = null;

for (let cp = 0; cp <= MAX_CODEPOINT; cp++) {
  if (cp >= SURROGATE_LO && cp <= SURROGATE_HI) {
    // Not a scalar value — treat as a hard break in any open range, same as
    // a non-matching codepoint would.
    if (rangeStart !== null) {
      ranges.push([rangeStart, cp - 1]);
      rangeStart = null;
    }
    continue;
  }

  if (matches(cp)) {
    if (rangeStart === null) rangeStart = cp;
  } else if (rangeStart !== null) {
    ranges.push([rangeStart, cp - 1]);
    rangeStart = null;
  }
}
if (rangeStart !== null) ranges.push([rangeStart, MAX_CODEPOINT]);

const rangeLines = ranges
  .map(([lo, hi]) => `    .{ 0x${lo.toString(16)}, 0x${hi.toString(16)} },`)
  .join("\n");

const contents = `//! GENERATED FILE — do not hand-edit.
//!
//! Regenerate with:
//!     bun runtime/scripts/gen-unicode-word-table.ts
//! (from the repo root; run \`cd runtime && bun install --frozen-lockfile\`
//! once in a fresh worktree first). See that script's header comment for the
//! generation method and its Unicode-version caveat.
//!
//! \`ranges\` covers every Unicode General_Category L* (letter) or N*
//! (number) codepoint as classified by the Bun/V8 build that generated this
//! file — an APPROXIMATION of GitHub's own heading-anchor classification,
//! not a guaranteed exact match. Used by \`src/heading_slugs.zig\`'s slugifier
//! to decide which codepoints survive GitHub-compatible slugification.

const std = @import("std");

/// Sorted, non-overlapping, inclusive [start, end] codepoint ranges for
/// Unicode General_Category L* (letter) or N* (number). ${ranges.length} ranges.
const ranges: []const [2]u21 = &.{
${rangeLines}
};

/// Binary search over \`ranges\`. Contract 3 (caller-buffer): allocates
/// nothing, just reads the comptime-embedded table.
pub fn isLetterOrNumber(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

test "isLetterOrNumber: ascii letters, digits, punctuation" {
    try std.testing.expect(isLetterOrNumber('a'));
    try std.testing.expect(isLetterOrNumber('Z'));
    try std.testing.expect(isLetterOrNumber('5'));
    try std.testing.expect(!isLetterOrNumber(' '));
    try std.testing.expect(!isLetterOrNumber('-'));
    try std.testing.expect(!isLetterOrNumber('_'));
    try std.testing.expect(!isLetterOrNumber(0x2014)); // em dash
}

test "isLetterOrNumber: representative non-ascii letters" {
    try std.testing.expect(isLetterOrNumber(0x00e9)); // é (LATIN SMALL LETTER E WITH ACUTE)
    try std.testing.expect(isLetterOrNumber(0x4e2d)); // 中 (CJK)
    try std.testing.expect(isLetterOrNumber(0x0430)); // а (CYRILLIC SMALL LETTER A)
}
`;

writeFileSync(OUT_PATH, contents);

const fmt = spawnSync("zig", ["fmt", OUT_PATH], {
  cwd: REPO_ROOT,
  stdio: "inherit",
});
if (fmt.status !== 0) {
  console.error(
    `gen-unicode-word-table: wrote ${OUT_PATH} but \`zig fmt\` failed (status ${fmt.status}); the file may not be fmt-clean.`,
  );
  process.exit(1);
}

console.log(`wrote ${OUT_PATH} (${ranges.length} ranges)`);
