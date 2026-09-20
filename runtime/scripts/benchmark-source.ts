import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";

// Include the whole runtime source tree rather than maintaining a dependency
// shortlist. Tests and fixtures are deliberately included in this conservative
// scope; installed dependencies and generated build output are not.
const scope = ["runtime", "src/cli/release.zig"];
const excludedDirectories = new Set(["node_modules", "dist", "build", "coverage", ".cache", ".zig-cache", "zig-out", ".zigapagos-cache"]);
const included = (file: string) => !file.split("/").some((part) => excludedDirectories.has(part));

export function sourceIdentity(repo: string) {
  const git = (...args: string[]) => {
    const result = Bun.spawnSync(["git", ...args], { cwd: repo });
    if (result.exitCode !== 0) throw new Error("unable to identify benchmark implementation revision");
    return result.stdout.toString();
  };
  const paths = (...args: string[]) => git(...args, "--", ...scope).split("\0").filter((file) => file && included(file));
  const revision = git("rev-parse", "HEAD").trim();
  const tracked = paths("ls-files", "--cached", "-z");
  const untracked = paths("ls-files", "--others", "--exclude-standard", "-z");
  // HEAD includes staged edits/deletions. Disabling rename detection keeps both
  // old and new names in the inventory, including staged deletions.
  const changed = [...new Set([
    ...paths("diff", "--name-only", "--no-renames", "-z", "HEAD"),
    ...paths("diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD"),
  ])];
  const files = Object.fromEntries([...new Set([...tracked, ...untracked, ...changed])].sort().map((file) => {
    try {
      return [file, createHash("sha256").update(readFileSync(join(repo, file))).digest("hex")];
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT" && changed.includes(file)) return [file, null];
      throw error;
    }
  }));
  return { revision, modified: changed.length > 0 || untracked.length > 0, scope, excludedDirectories: [...excludedDirectories].sort(), files };
}
