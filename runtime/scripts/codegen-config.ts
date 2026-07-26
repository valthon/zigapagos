// Loader for the optional `contract/codegen.config.json` codegen-mode config.
//
// Consumed by apiclient.ts (the api-gen / api-check dispatcher) and, at
// configure time, by build.zig (which only reads `mode` to pick which branch
// to wire). Absent config => `openapi` mode (today's behavior, unchanged).
//
// Shape:
//   {
//     "mode": "openapi" | "zigbase",          // absent => "openapi"
//     "zigbase": {                            // required iff mode === "zigbase"
//       "genClientCmd": ["zig","build","gen-client"], // backend gen-client command
//       "genClientCwd": "../backend",         // where to run it (cwd-relative or abs)
//       "out":          "contract/generated/zbase.gen.ts", // vendored dest in app tree
//       "apiPrefix":    "/api",               // passed through / documented
//       "producedPath": "clients/typescript/zbase.gen.ts"  // OPTIONAL: where the
//         // command writes its output, relative to genClientCwd. When set,
//         // api-gen copies producedPath -> out (backends like golfsim hardcode
//         // their own out path). When omitted, genClientCmd is expected to
//         // write `out` directly.
//     }
//   }
//
// All paths (genClientCwd, out, producedPath) are resolved relative to the
// process cwd (repo root when invoked by build.zig); absolute paths pass through.
import { existsSync, readFileSync } from "node:fs";

export interface ZigbaseCodegenConfig {
  /** Backend gen-client command, argv form (e.g. ["zig","build","gen-client"]). */
  genClientCmd: string[];
  /** Directory to run genClientCmd in (cwd-relative or absolute). */
  genClientCwd: string;
  /** Vendored client destination in the app tree (cwd-relative or absolute). */
  out: string;
  /** API prefix passed to / documented for the backend generator. */
  apiPrefix: string;
  /**
   * Optional: path (relative to genClientCwd) the command writes its output to.
   * When set, api-gen copies it to `out`. When omitted, the command is expected
   * to write `out` directly.
   */
  producedPath?: string;
}

export type CodegenMode = "openapi" | "zigbase";

export interface CodegenConfig {
  mode: CodegenMode;
  zigbase?: ZigbaseCodegenConfig;
}

export const DEFAULT_CONFIG: CodegenConfig = { mode: "openapi" };

const CONFIG_NAME = "contract/codegen.config.json";

function requireString(v: unknown, where: string): string {
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`${CONFIG_NAME}: ${where} must be a non-empty string`);
  }
  return v;
}

/**
 * Validate an already-JSON-parsed config value into the normalized shape.
 * Loud-fail on bad shape. Absent `mode` => "openapi".
 */
export function validateCodegenConfig(raw: unknown): CodegenConfig {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`${CONFIG_NAME}: top level must be an object`);
  }
  const obj = raw as Record<string, unknown>;
  const mode = obj.mode ?? "openapi";
  if (mode !== "openapi" && mode !== "zigbase") {
    throw new Error(`${CONFIG_NAME}: mode must be "openapi" or "zigbase" (got ${JSON.stringify(mode)})`);
  }

  if (mode === "openapi") {
    // zigbase block is ignored in openapi mode; keep the config minimal.
    return { mode };
  }

  // mode === "zigbase" — the zigbase block is required and fully validated.
  const zb = obj.zigbase;
  if (zb === undefined || zb === null || typeof zb !== "object" || Array.isArray(zb)) {
    throw new Error(`${CONFIG_NAME}: zigbase mode requires a "zigbase" object`);
  }
  const z = zb as Record<string, unknown>;

  if (!Array.isArray(z.genClientCmd) || z.genClientCmd.length === 0) {
    throw new Error(`${CONFIG_NAME}: zigbase.genClientCmd must be a non-empty array of strings`);
  }
  for (const e of z.genClientCmd) {
    if (typeof e !== "string") {
      throw new Error(`${CONFIG_NAME}: zigbase.genClientCmd entries must be strings`);
    }
  }

  const cfg: ZigbaseCodegenConfig = {
    genClientCmd: z.genClientCmd as string[],
    genClientCwd: requireString(z.genClientCwd, "zigbase.genClientCwd"),
    out: requireString(z.out, "zigbase.out"),
    apiPrefix: requireString(z.apiPrefix, "zigbase.apiPrefix"),
  };
  if (z.producedPath !== undefined) {
    cfg.producedPath = requireString(z.producedPath, "zigbase.producedPath");
  }

  return { mode, zigbase: cfg };
}

/**
 * Load the codegen config from `path` (default `contract/codegen.config.json`,
 * cwd-relative). Returns DEFAULT_CONFIG (openapi) when the file is absent.
 */
export function loadCodegenConfig(path: string = CONFIG_NAME): CodegenConfig {
  if (!existsSync(path)) return { ...DEFAULT_CONFIG };
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`${CONFIG_NAME}: failed to read/parse ${path}: ${e instanceof Error ? e.message : String(e)}`);
  }
  return validateCodegenConfig(raw);
}
