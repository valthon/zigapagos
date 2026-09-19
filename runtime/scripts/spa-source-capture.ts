// A fresh handoff between the successful client bundle and its isolated slicer.
// This is not a persistent cache: release clears staging before every build.
import { readFileSync, realpathSync } from "node:fs";
import { createHash } from "node:crypto";

const digest = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
export function makeSourceCapture(entry: string, paths: string[], configPath: string | null | undefined, configFiles: string[], minify: boolean) {
  try {
    paths = [...new Set(paths.map((path) => realpathSync(path)))];
    configFiles = [...new Set(configFiles.map((path) => realpathSync(path)))].sort();
    return {
      version: 2, entry: realpathSync(entry), paths, configPath: configPath ? realpathSync(configPath) : null, configFiles, minify,
      inputs: [...new Set([...paths, ...configFiles])].map((path) => ({path, sha256:digest(path)})),
    };
  } catch {
    // The successful bundle remains valid if its optional capture cannot be
    // read. Write a null handoff so the isolated slicer rediscovers normally.
    return null;
  }
}

/** Unknown, mismatched, or changed captures force normal graph discovery. */
export function readSourceCapture(path: string, entry: string, configPath: string | null | undefined, configFiles: string[], minify: boolean): string[] | null {
  try {
    entry = realpathSync(entry);
    configPath = configPath ? realpathSync(configPath) : null;
    configFiles = [...new Set(configFiles.map((path) => realpathSync(path)))].sort();
    const data = JSON.parse(readFileSync(path, "utf8"));
    if (data.version !== 2 || data.entry !== entry || data.configPath !== (configPath ?? null) || data.minify !== minify ||
        JSON.stringify(data.configFiles) !== JSON.stringify(configFiles) || !Array.isArray(data.paths) || !data.paths.every((p: unknown) => typeof p === "string") || !Array.isArray(data.inputs)) return null;
    const inputs = new Set<string>();
    for (const input of data.inputs) {
      if (typeof input.path !== "string" || typeof input.sha256 !== "string" || digest(input.path) !== input.sha256) return null;
      inputs.add(input.path);
    }
    if (!data.paths.includes(entry) || data.paths.some((p: string) => !inputs.has(p)) || configFiles.some((p) => !inputs.has(p))) return null;
    return data.paths;
  } catch {
    // Capture is an optimization only; unreadable or invalid input must never
    // narrow the graph. The original discovery build diagnoses real failures.
    return null;
  }
}
