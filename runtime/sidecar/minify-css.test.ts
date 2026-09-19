import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

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

test("batch matches independent builds, including duplicate basenames and escaped paths", () => {
  const dir = tmp();
  const pairs = ["one/theme.css", "two/theme.css", 'quote" and space.css', "empty.css"].map((name, i) => {
    const input = join(dir, name);
    const output = join(dir, "batch", name);
    const legacy = join(dir, "legacy", name);
    mkdirSync(dirname(input), { recursive: true });
    writeFileSync(input, i === 3 ? "" : `@import "../reset.css";\n@layer theme { .item-${i} { --color: red; color: var(--color); background: url('/image ${i}.png'); margin: 1px 1px; } }`);
    expect(run([input, legacy]).code).toBe(0);
    return { input, output, legacy };
  });
  const p = Bun.spawnSync([process.execPath, SCRIPT, "--batch"], {
    stdin: Buffer.from(pairs.map(({ input, output }) => JSON.stringify({ input, output })).join("\n") + "\n"),
  });
  expect(p.stderr.toString()).toBe("");
  expect(p.exitCode).toBe(0);
  for (const { output, legacy } of pairs) expect(readFileSync(output)).toEqual(readFileSync(legacy));
});

test("batch surfaces offending CSS and rejects malformed requests", () => {
  const dir = tmp();
  const input = join(dir, "broken.css");
  const output = join(dir, "out.css");
  writeFileSync(input, "@import ;");
  for (const request of [JSON.stringify({ input, output }), '{"input":42}', "invalid json"]) {
    const p = Bun.spawnSync([process.execPath, SCRIPT, "--batch"], { stdin: Buffer.from(request + "\n") });
    expect(p.exitCode).toBe(1);
    expect(p.stderr.length).toBeGreaterThan(0);
    if (request.includes("broken.css")) expect(p.stderr.toString()).toContain("broken.css");
  }
  expect(existsSync(output)).toBe(false);
});
