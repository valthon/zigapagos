import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "minify-css.ts");

function run(args: string[]): { code: number; stderr: string } {
  const p = Bun.spawnSync(["bun", SCRIPT, ...args]);
  return { code: p.exitCode ?? -1, stderr: p.stderr.toString() };
}

function tmp(): string {
  return mkdtempSync(join(tmpdir(), "minify-css-"));
}

test("minifies CSS: strips comments and whitespace, shrinks output", () => {
  const dir = tmp();
  const src = join(dir, "style.css");
  const out = join(dir, "style.min.css");
  const source = `/* a design-system comment */
.foo {
    color: #ff0000;
    margin: 10px 10px 10px 10px;
}

.bar   ,   .baz {
    display: flex;
}
`;
  writeFileSync(src, source);

  const { code, stderr } = run([src, out]);
  expect(stderr).toBe("");
  expect(code).toBe(0);

  const minified = readFileSync(out, "utf8");
  // Comment gone, smaller, and the rendered declarations survive.
  expect(minified).not.toContain("/*");
  expect(minified).not.toContain("design-system");
  expect(minified.length).toBeLessThan(source.length);
  expect(minified).toContain("display:flex");
  // color:#ff0000 collapses to color:red, margin shorthand collapses.
  expect(minified).toContain("color:red");
});

test("preserves url() and @import targets verbatim (pure minify, no bundling)", () => {
  const dir = tmp();
  const src = join(dir, "u.css");
  const out = join(dir, "u.min.css");
  writeFileSync(
    src,
    `@import "/vendor/reset.css";
.hero { background-image: url("/img/bg.png"); }
@font-face { font-family: X; src: url("/fonts/x.woff2"); }
`,
  );

  const { code, stderr } = run([src, out]);
  expect(stderr).toBe("");
  expect(code).toBe(0);

  const minified = readFileSync(out, "utf8");
  // Absolute paths kept exactly — no resolve, no hashing, no rewrite.
  expect(minified).toContain("/img/bg.png");
  expect(minified).toContain("/fonts/x.woff2");
  expect(minified).toContain("/vendor/reset.css");
});

test("fails (non-zero) on broken CSS instead of writing output", () => {
  const dir = tmp();
  const src = join(dir, "broken.css");
  const out = join(dir, "broken.min.css");
  // A real CSS parse error (Bun/Lightning CSS rejects it).
  writeFileSync(src, "@import ;");

  const { code, stderr } = run([src, out]);
  expect(code).not.toBe(0);
  // The error is surfaced (the Zig caller inherits this stderr into the build log).
  expect(stderr.length).toBeGreaterThan(0);
});

test("usage error (exit 2) when args are missing", () => {
  const { code } = run([]);
  expect(code).toBe(2);
});
