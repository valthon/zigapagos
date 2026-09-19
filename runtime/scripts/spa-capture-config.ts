// Capture-only config identity. Do not approximate TypeScript's resolver:
// unsupported JSONC/package/array extends disable this optimization entirely.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

export function captureConfigFiles(entry: string, siteConfig: string | null): string[] | null {
  try {
    const files = new Set<string>();
    const visiting = new Set<string>();
    function visit(path: string): boolean {
      const canonical = realpathSync(path);
      // A file symlink into another directory makes relative extends resolution
      // ambiguous. Directory aliases (e.g. /var -> /private/var) stay supported.
      if (realpathSync(dirname(resolve(path))) !== dirname(canonical)) return false;
      if (visiting.has(canonical)) return false;
      if (files.has(canonical)) return true;
      visiting.add(canonical);
      const config = JSON.parse(readFileSync(canonical, "utf8"));
      if (!config || typeof config !== "object" || Array.isArray(config)) return false;
      if (Object.hasOwn(config, "extends")) {
        const base = config.extends;
        if (typeof base !== "string" || (!base.startsWith("./") && !base.startsWith("../") && !isAbsolute(base))) return false;
        const target = resolve(dirname(canonical), base);
        // Relative extensionless JSON configs are a supported spelling. Do not
        // guess package exports, directory defaults, or alternative extensions.
        const file = existsSync(target) ? target : target + ".json";
        if (!visit(file)) return false;
      }
      visiting.delete(canonical);
      files.add(canonical);
      return true;
    }
    // Hash both ancestry spellings: Bun may resolve an entry alias before
    // discovering configs. Taking the union is conservative without guessing.
    for (const start of [dirname(resolve(entry)), dirname(realpathSync(entry))]) {
      let dir = start;
      for (;;) {
        const config = join(dir, "tsconfig.json");
        if (existsSync(config) && !visit(config)) return null;
        const parent = dirname(dir);
        if (parent === dir) break;
        dir = parent;
      }
    }
    if (siteConfig) files.add(realpathSync(siteConfig));
    return [...files].sort();
  } catch {
    // A missing/unreadable/cyclic/unsupported config is not proof of an
    // unchanged graph. The original Bun discovery path remains authoritative.
    return null;
  }
}
