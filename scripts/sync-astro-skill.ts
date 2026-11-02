// Keep the standalone skill usable after installation outside this checkout.
// Canonical migration docs stay authoritative; links outside the packaged
// reference set point to their canonical repository pages.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";

const root = resolve(import.meta.dir, "..");
const names = ["astro-to-zigapagos.md", "recipes.md", "react-spa-bridge.md"];
let stale = false;
for (const name of names) {
  const source = resolve(root, "docs/migration", name);
  let fence = false;
  const output = readFileSync(source, "utf8").split("\n").map(line => {
    if (/^\s*```/.test(line)) { fence = !fence; return line; }
    if (fence) return line;
    return line.replace(/\]\(([^()\s]+)\)/g, (whole, href: string) => {
      if (/^(?:#|\/|[a-z]+:)/i.test(href)) return whole;
      const [path, fragment] = href.split("#");
      const target = resolve(dirname(source), path);
      if (!existsSync(target)) throw new Error(`${source}: broken reference ${href}`);
      if (names.some(n => target === resolve(root, "docs/migration", n))) return whole;
      return `](https://github.com/valthon/zigapagos/blob/main/${relative(root, target)}${fragment ? "#" + fragment : ""})`;
    });
  }).join("\n");
  const destination = resolve(root, "skills/zigapagos-astro-migration/references", name);
  if (readFileSync(destination, "utf8") !== output) {
    stale = true;
    if (process.argv.includes("--check")) console.error(`stale skill reference: ${name}; run bun scripts/sync-astro-skill.ts`);
    else writeFileSync(destination, output);
  }
}
if (stale && process.argv.includes("--check")) process.exit(1);
