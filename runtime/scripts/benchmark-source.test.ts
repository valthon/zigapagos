import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { sourceIdentity } from "./benchmark-source.ts";

function fixture(run: (dir: string, git: (...args: string[]) => void, write: (path: string, text: string) => void) => void) {
  const dir = mkdtempSync(join(tmpdir(), "benchmark-source-"));
  const git = (...args: string[]) => {
    const child = Bun.spawnSync(["git", ...args], { cwd: dir });
    if (child.exitCode !== 0) throw new Error(child.stderr.toString());
  };
  const write = (path: string, text: string) => { mkdirSync(dirname(join(dir, path)), { recursive: true }); writeFileSync(join(dir, path), text); };
  try {
    git("init", "-q");
    for (const path of ["runtime/scripts/react-alias.ts", "runtime/sidecar/ssr-resolve.ts", "runtime/scripts/z-runtime-config.ts", "runtime/scripts/site-data.ts", "runtime/src/index.ts", "runtime/bun.lock", "runtime/package.json", "src/cli/release.zig"]) write(path, "initial");
    write(".gitignore", "runtime/ignored/\n");
    git("add", ".");
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture");
    run(dir, git, write);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("runtime inventory detects unstaged and staged changes beyond the former shortlist", () => fixture((dir, git, write) => {
  const initial = sourceIdentity(dir);
  expect(initial.modified).toBe(false);
  expect(Object.keys(initial.files)).toHaveLength(8);
  write("runtime/scripts/react-alias.ts", "edited alias");
  const unstaged = sourceIdentity(dir);
  expect(unstaged.modified).toBe(true);
  expect(unstaged.files["runtime/scripts/react-alias.ts"]).not.toBe(initial.files["runtime/scripts/react-alias.ts"]);
  git("restore", "runtime/scripts/react-alias.ts");
  write("runtime/sidecar/ssr-resolve.ts", "edited resolver");
  git("add", "runtime/sidecar/ssr-resolve.ts");
  const staged = sourceIdentity(dir);
  expect(staged.modified).toBe(true);
  expect(staged.revision).toBe(initial.revision);
  expect(staged.files["runtime/sidecar/ssr-resolve.ts"]).not.toBe(initial.files["runtime/sidecar/ssr-resolve.ts"]);
  // The index can differ even when the working file has returned to HEAD bytes.
  write("runtime/sidecar/ssr-resolve.ts", "initial");
  expect(sourceIdentity(dir).modified).toBe(true);
  expect(sourceIdentity(dir).files).toEqual(initial.files);
}));

test("new runtime files are discovered without an allowlist, including unusual paths", () => fixture((dir, git, write) => {
  const path = "runtime/src/new component\nwith newline.ts";
  write(path, "new implementation");
  const untracked = sourceIdentity(dir);
  expect(untracked.modified).toBe(true);
  expect(untracked.files[path]).toMatch(/^[a-f0-9]{64}$/);
  git("add", path);
  expect(sourceIdentity(dir).files).toEqual(untracked.files);
  expect(sourceIdentity(dir).modified).toBe(true);
}));

test("runtime lockfile changes and staged deletions retain accurate provenance", () => fixture((dir, git, write) => {
  const initial = sourceIdentity(dir);
  write("runtime/bun.lock", "updated resolution");
  expect(sourceIdentity(dir).files["runtime/bun.lock"]).not.toBe(initial.files["runtime/bun.lock"]);
  expect(sourceIdentity(dir).modified).toBe(true);
  git("restore", "runtime/bun.lock");
  rmSync(join(dir, "runtime/scripts/site-data.ts"));
  expect(sourceIdentity(dir).files["runtime/scripts/site-data.ts"]).toBeNull();
  git("add", "runtime/scripts/site-data.ts");
  expect(sourceIdentity(dir).files["runtime/scripts/site-data.ts"]).toBeNull();
  expect(sourceIdentity(dir).modified).toBe(true);
}));

test("dependencies, generated output, ignored files and unrelated docs are excluded", () => fixture((dir, git, write) => {
  const initial = sourceIdentity(dir);
  for (const path of ["runtime/node_modules/pkg/index.ts", "runtime/dist/output.js", "runtime/.cache/cache.json", "runtime/ignored/local.ts", "docs/note.md"]) write(path, "not implementation identity");
  expect(sourceIdentity(dir).files).toEqual(initial.files);
  expect(sourceIdentity(dir).modified).toBe(false);
  // Explicit exclusions still apply if generated output was accidentally staged.
  git("add", "runtime/dist/output.js");
  expect(sourceIdentity(dir).modified).toBe(false);
  expect(sourceIdentity(dir).files).toEqual(initial.files);
}));
