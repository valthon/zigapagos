import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

/**
 * Maps an OpenAPI JSON Schema subset to a TypeScript type string.
 *
 * Supported:
 *   - Scalars: string / number / integer / boolean
 *   - Arrays:  { type:"array", items: S } → T[]
 *   - Maps:    { type:"object", additionalProperties: S } (no/empty properties) → Record<string, T>
 *   - Enums:   { type:"string", enum: [...] } → "a" | "b"
 *   - Refs:    { $ref:"#/components/schemas/Name" } → Name
 *
 * NOT supported (throws):
 *   - oneOf / allOf / anyOf
 *   - $ref to a non-#/components/schemas/ target
 *   - Nested inline objects (type:"object" with properties but no additionalProperties)
 *     — only top-level schemas are emitted as interfaces; use $ref for nested objects.
 *   - Unknown / missing type (when not a $ref and not an enum)
 */
export function tsTypeOf(schema: any): string {
  // $ref — resolve to the referenced schema name
  if ("$ref" in schema) {
    const ref: string = schema.$ref;
    const prefix = "#/components/schemas/";
    if (!ref.startsWith(prefix)) {
      throw new Error(
        `apigen: unsupported $ref target (only ${prefix}* allowed): ${JSON.stringify(schema)}`,
      );
    }
    return ref.slice(prefix.length);
  }

  // Unsupported combiners
  if ("oneOf" in schema || "allOf" in schema || "anyOf" in schema) {
    throw new Error(
      `apigen: unsupported schema (oneOf/allOf/anyOf not supported): ${JSON.stringify(schema)}`,
    );
  }

  const type: string | undefined = schema.type;

  // Enum string-literal union (must check before generic string branch)
  if (type === "string" && Array.isArray(schema.enum)) {
    return (schema.enum as string[]).map((v) => `"${v}"`).join(" | ");
  }

  // Scalar types
  if (type === "string") return "string";
  if (type === "number") return "number";
  if (type === "integer") return "number";
  if (type === "boolean") return "boolean";

  // Array
  if (type === "array") {
    if (!schema.items) {
      throw new Error("apigen: unsupported array without items: " + JSON.stringify(schema));
    }
    return `${tsTypeOf(schema.items)}[]`;
  }

  // Object
  if (type === "object") {
    const hasAdditionalProps = schema.additionalProperties != null;
    const hasProperties =
      schema.properties != null && Object.keys(schema.properties).length > 0;

    if (hasAdditionalProps) {
      // additionalProperties wins for type emission (map type)
      // Note: if both properties AND additionalProperties exist, the
      // additionalProperties map is returned — top-level schemas with both
      // are handled separately by emitTypes (emitting an interface for the
      // declared properties and ignoring additionalProperties at schema level).
      if (typeof schema.additionalProperties !== "object" || schema.additionalProperties === null) {
        throw new Error(
          "apigen: unsupported additionalProperties (must be a schema object): " + JSON.stringify(schema),
        );
      }
      return `Record<string, ${tsTypeOf(schema.additionalProperties)}>`;
    }

    if (hasProperties) {
      // Nested inline object — not supported; only $ref-based nesting is.
      throw new Error(
        `apigen: unsupported nested inline object (use $ref for nested objects): ${JSON.stringify(schema)}`,
      );
    }

    // Bare empty object
    return "Record<string, unknown>";
  }

  throw new Error(
    `apigen: unsupported schema (unknown/missing type): ${JSON.stringify(schema)}`,
  );
}

/**
 * Emits TypeScript source (`types.ts`) for all schemas in doc.components.schemas.
 *
 * Iterates in Object.keys (declaration) order — stable, not sorted.
 *
 * Each schema is emitted as:
 *   - `export interface Name { prop?: T; ... }` for type:object with properties
 *   - `export type Name = Record<string, T>;` for pure additionalProperties maps
 *
 * Appends `export const CONTRACT_VERSION = "..."` from doc['x-zigbase-contract-version'].
 *
 * FAILS LOUD on oneOf/allOf/anyOf or unknown constructs (throws).
 */
export function emitTypes(doc: any): string {
  const schemas: Record<string, any> = doc.components?.schemas ?? {};
  const lines: string[] = [];

  for (const name of Object.keys(schemas)) {
    const schema = schemas[name];

    // Detect unsupported combiners at the top level early
    if ("oneOf" in schema || "allOf" in schema || "anyOf" in schema) {
      throw new Error(
        `apigen: unsupported schema (oneOf/allOf/anyOf not supported): ${JSON.stringify(schema)}`,
      );
    }

    const properties: Record<string, any> = schema.properties ?? {};
    const required: string[] = schema.required ?? [];
    const propKeys = Object.keys(properties);
    const hasAdditionalProps = schema.additionalProperties != null;

    // Pure additionalProperties map (no declared properties) → type alias
    if (hasAdditionalProps && propKeys.length === 0) {
      lines.push(`export type ${name} = ${tsTypeOf(schema)};`);
      lines.push("");
      continue;
    }

    // Object with declared properties → interface
    lines.push(`export interface ${name} {`);
    for (const propName of propKeys) {
      const propSchema = properties[propName];
      const isRequired = required.includes(propName);
      const opt = isRequired ? "" : "?";
      lines.push(`  ${propName}${opt}: ${tsTypeOf(propSchema)};`);
    }
    lines.push("}");
    lines.push("");
  }

  const version: string = doc["x-zigbase-contract-version"] ?? "";
  lines.push(`export const CONTRACT_VERSION = "${version}";`);
  lines.push("");

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// extractSchemaRef — resolve a $ref string from either:
//   - direct { $ref: "..." }  (test/simplified format)
//   - OpenAPI 3.x { content: { "application/json": { schema: { $ref } } } }
// Returns the schema name (after "#/components/schemas/") or undefined.
// ---------------------------------------------------------------------------
function extractSchemaRef(obj: any): string | undefined {
  if (!obj) return undefined;
  const prefix = "#/components/schemas/";
  // Direct $ref (simplified test format or OpenAPI $ref-wrapped object)
  if (typeof obj.$ref === "string") return obj.$ref.replace(prefix, "");
  // OpenAPI 3.x content wrapper
  const schema = obj.content?.["application/json"]?.schema;
  if (typeof schema?.$ref === "string") return schema.$ref.replace(prefix, "");
  return undefined;
}

// ---------------------------------------------------------------------------
// toPascalSegments — converts a path segment or series to PascalCase.
// e.g. ["club", "login"] → "ClubLogin"
// ---------------------------------------------------------------------------
function toPascalSegments(segments: string[]): string {
  return segments.map((s) => s.charAt(0).toUpperCase() + s.slice(1)).join("");
}

// ---------------------------------------------------------------------------
// Validator emitter helpers
// ---------------------------------------------------------------------------

/**
 * Determines what kind of runtime check is appropriate for a schema field.
 * Returns null for unknown/unsupported schema constructs.
 */
function schemaCheckKind(
  schema: any,
): { kind: "typeof"; typeName: string } | { kind: "isArray" } | { kind: "isObject" } | null {
  if ("$ref" in schema) return { kind: "isObject" }; // $ref → check it's an object
  const type = schema.type;
  if (type === "string") return { kind: "typeof", typeName: "string" };
  if (type === "boolean") return { kind: "typeof", typeName: "boolean" };
  if (type === "number" || type === "integer") return { kind: "typeof", typeName: "number" };
  if (type === "array") return { kind: "isArray" };
  if (type === "object") return { kind: "isObject" };
  return null;
}

/**
 * Builds the lines for a loud-fail assert function for the given schema.
 * Required fields: presence + primitive-type check (throws on mismatch).
 * Optional fields: if present, type-checked; if absent, OK.
 *
 * e.g. assertContactResponse(x: any): void
 *   if (typeof x?.ok !== "boolean") throw new Error("contract violation: ContactResponse.ok must be boolean");
 */
function buildAssertFn(typeName: string, schema: any): string[] {
  const lines: string[] = [];
  lines.push(`function assert${typeName}(x: any): void {`);

  const properties: Record<string, any> = schema.properties ?? {};
  const required: string[] = schema.required ?? [];

  for (const [propName, propSchema] of Object.entries(properties)) {
    const isRequired = required.includes(propName);
    const check = schemaCheckKind(propSchema);
    if (!check) continue; // skip unknowns

    if (check.kind === "typeof") {
      if (isRequired) {
        lines.push(
          `  if (typeof x?.${propName} !== "${check.typeName}") throw new Error("contract violation: ${typeName}.${propName} must be ${check.typeName}");`,
        );
      } else {
        lines.push(
          `  if (x?.${propName} !== undefined && typeof x?.${propName} !== "${check.typeName}") throw new Error("contract violation: ${typeName}.${propName} must be ${check.typeName}");`,
        );
      }
    } else if (check.kind === "isArray") {
      if (isRequired) {
        lines.push(
          `  if (!Array.isArray(x?.${propName})) throw new Error("contract violation: ${typeName}.${propName} must be array");`,
        );
      } else {
        lines.push(
          `  if (x?.${propName} !== undefined && !Array.isArray(x?.${propName})) throw new Error("contract violation: ${typeName}.${propName} must be array");`,
        );
      }
    } else {
      // isObject
      if (isRequired) {
        lines.push(
          `  if (typeof x?.${propName} !== "object" || x?.${propName} === null || Array.isArray(x?.${propName})) throw new Error("contract violation: ${typeName}.${propName} must be object");`,
        );
      } else {
        lines.push(
          `  if (x?.${propName} !== undefined && (typeof x?.${propName} !== "object" || x?.${propName} === null || Array.isArray(x?.${propName}))) throw new Error("contract violation: ${typeName}.${propName} must be object");`,
        );
      }
    }
  }

  lines.push(`}`);
  return lines;
}

/**
 * Emits TypeScript source (`client.ts`) from doc.paths.
 *
 * GET endpoints → URL const + prime<Name>(): void + read<Name>(): ResponseType
 *   using host.fetchShared / host.store.getJson.
 * POST endpoints → async post<Name>(req: ReqType): Promise<ResType>
 *   using host.fetchOpts; throws on status === 0 (network error).
 *
 * Function names are derived from path segments, NOT special-cased by path string.
 * Request/response type names are derived from the $ref values in the path item.
 *
 * Imports: `@z/runtime/host` + `./types.ts` ONLY.
 * NEVER imports Preact or bare `@z/runtime`.
 *
 * opts.validators:
 *   "post" (default) — emit assertX() loud-fail shape-checkers for POST response schemas
 *                      and call them before returning parsed POST responses.
 *   "all"            — same as "post" for v1 (GET validators are out of scope).
 *   "none"           — no assert functions; POST wrappers cast and return directly.
 */
export function emitClient(doc: any, opts?: { validators?: "post" | "all" | "none" }): string {
  const validatorMode = opts?.validators ?? "post";
  const emitPostValidators = validatorMode === "post" || validatorMode === "all";

  const schemas: Record<string, any> = doc.components?.schemas ?? {};
  const paths: Record<string, any> = doc.paths ?? {};
  const lines: string[] = [];

  // Collect all type names referenced by the client so we know what to import.
  const typeNames = new Set<string>();

  // Structured endpoint info collected in one pass over paths.
  type GetEp = {
    path: string;
    urlConst: string;
    storeName: string;
    fnBase: string;
    responseType: string;
  };
  type PostEp = {
    path: string;
    fnName: string;
    reqType: string;
    resType: string;
  };
  const getEndpoints: GetEp[] = [];
  const postEndpoints: PostEp[] = [];

  for (const [path, methods] of Object.entries(paths as Record<string, any>)) {
    // GET endpoints — prime/read shared-fetch pattern
    if (methods.get) {
      const responseType = extractSchemaRef(methods.get.responses?.["200"]);
      if (!responseType) {
        throw new Error(
          `apigen: unsupported inline schema for GET ${path}; the codegen requires a $ref to components.schemas (got an inline schema)`,
        );
      }
      typeNames.add(responseType);

      // Derive storeName from path: /api/<store>/state → store segment
      // e.g. /api/flags/state → "flags"; /api/metrics/state → "metrics"
      // General rule: drop leading "api" and trailing "state"; use the middle.
      // Fallback: use the last non-"state" segment.
      const segs = path.split("/").filter(Boolean); // ["api", "flags", "state"]
      const nonApiSegs = segs.slice(1); // ["flags", "state"]
      const lastSeg = nonApiSegs[nonApiSegs.length - 1];
      let storeName: string;
      if (lastSeg === "state" && nonApiSegs.length >= 2) {
        storeName = nonApiSegs[nonApiSegs.length - 2];
      } else {
        storeName = lastSeg ?? segs[segs.length - 1];
      }
      const fnBase = storeName.charAt(0).toUpperCase() + storeName.slice(1);
      const urlConst = storeName.toUpperCase() + "_URL";

      getEndpoints.push({ path, urlConst, storeName, fnBase, responseType });
    }

    // POST endpoints — typed fetch with JSON body
    if (methods.post) {
      const reqType = extractSchemaRef(methods.post.requestBody);
      const resType = extractSchemaRef(methods.post.responses?.["200"]);
      if (!reqType || !resType) {
        throw new Error(
          `apigen: unsupported inline schema for POST ${path}; the codegen requires a $ref to components.schemas (got an inline schema)`,
        );
      }
      typeNames.add(reqType);
      typeNames.add(resType);

      // Derive function name from path segments after /api/
      // /api/contact → ["contact"] → postContact
      // /api/club/login → ["club","login"] → postClubLogin
      const segs = path.split("/").filter(Boolean).slice(1); // drop "api"
      const fnName = "post" + toPascalSegments(segs);

      postEndpoints.push({ path, fnName, reqType, resType });
    }
  }

  // Imports — host first, then types
  lines.push(`import { host } from "@z/runtime/host";`);
  if (typeNames.size > 0) {
    const sorted = Array.from(typeNames).sort();
    lines.push(`import type { ${sorted.join(", ")} } from "./types.ts";`);
  }
  lines.push("");

  // GET endpoints
  for (const ep of getEndpoints) {
    lines.push(`export const ${ep.urlConst} = "${ep.path}";`);
    lines.push(
      `export function prime${ep.fnBase}(): void { host.fetchShared(${ep.urlConst}, "${ep.storeName}"); }`,
    );
    lines.push(
      `export function read${ep.fnBase}(): ${ep.responseType} { return host.store.getJson<${ep.responseType}>("${ep.storeName}"); }`,
    );
    lines.push("");
  }

  // POST-response validator functions (loud-fail shape-checkers)
  if (emitPostValidators) {
    for (const ep of postEndpoints) {
      const schema = schemas[ep.resType];
      if (schema) {
        const fnLines = buildAssertFn(ep.resType, schema);
        lines.push(...fnLines);
        lines.push("");
      }
    }
  }

  // POST endpoints
  for (const ep of postEndpoints) {
    lines.push(
      `export async function ${ep.fnName}(req: ${ep.reqType}): Promise<${ep.resType}> {`,
    );
    lines.push(
      `  const env = await host.fetchOpts({ url: "${ep.path}", method: "POST", headers: [{ name: "content-type", value: "application/json" }], body: JSON.stringify(req) });`,
    );
    lines.push(`  if (env.status === 0) throw new Error("${ep.fnName}: network error");`);
    if (emitPostValidators) {
      lines.push(`  const out = JSON.parse(env.body) as ${ep.resType};`);
      lines.push(`  assert${ep.resType}(out);`);
      lines.push(`  return out;`);
    } else {
      lines.push(`  return JSON.parse(env.body) as ${ep.resType};`);
    }
    lines.push(`}`);
    lines.push("");
  }

  return lines.join("\n");
}

/**
 * Emits TypeScript source (`_assert.ts`) — the structural-identity tripwire.
 *
 * Imports the generated ResolvedState (Gen) and the runtime's ResolvedState
 * (Runtime) and asserts bidirectional assignability via `tsc --noEmit`.
 * If ZigBase changes the envelope, regen changes Gen and one of the
 * assignments fails at compile time.
 *
 * The relative import `../../runtime/src/flags.ts` resolves from:
 *   contract/generated/_assert.ts → ../ = contract/ → ../ = repo root
 *   → runtime/src/flags.ts  ✓
 */
export function emitAssert(): string {
  return [
    `import type { ResolvedState as Gen } from "./types.ts";`,
    `import type { ResolvedState as Runtime } from "../../runtime/src/flags.ts";`,
    `// Structural identity: each must be assignable to the other. If ZigBase changes`,
    `// the envelope, regen changes Gen and one of these fails \`tsc --noEmit\`.`,
    `const _a: Gen = {} as Runtime;`,
    `const _b: Runtime = {} as Gen;`,
    `void _a; void _b;`,
    ``,
  ].join("\n");
}

// CLI: bun scripts/apigen.ts --schema <path> --out <dir> [--validators=post|all|none]
if (import.meta.main) {
  const args = process.argv.slice(2);
  let schemaPath = "";
  let outDir = "";
  let validators: "post" | "all" | "none" = "post";

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--schema") schemaPath = args[++i] ?? "";
    else if (args[i] === "--out") outDir = args[++i] ?? "";
    else if (args[i].startsWith("--validators=")) {
      const val = args[i].slice("--validators=".length);
      if (val !== "post" && val !== "all" && val !== "none") {
        console.error(
          `apigen: invalid --validators value "${val}"; must be post|all|none`,
        );
        process.exit(1);
      }
      validators = val as "post" | "all" | "none";
    } else if (args[i] === "--validators") {
      const val = args[++i] ?? "";
      if (val !== "post" && val !== "all" && val !== "none") {
        console.error(
          `apigen: invalid --validators value "${val}"; must be post|all|none`,
        );
        process.exit(1);
      }
      validators = val as "post" | "all" | "none";
    }
  }

  if (!schemaPath || !outDir) {
    console.error("Usage: apigen.ts --schema <path> --out <dir> [--validators=post|all|none]");
    process.exit(1);
  }

  const doc: unknown = JSON.parse(readFileSync(schemaPath, "utf8"));
  mkdirSync(outDir, { recursive: true });
  writeFileSync(`${outDir}/types.ts`, emitTypes(doc), "utf8");
  console.log(`apigen: wrote ${outDir}/types.ts`);
  writeFileSync(`${outDir}/client.ts`, emitClient(doc, { validators }), "utf8");
  console.log(`apigen: wrote ${outDir}/client.ts`);
  writeFileSync(`${outDir}/_assert.ts`, emitAssert(), "utf8");
  console.log(`apigen: wrote ${outDir}/_assert.ts`);
}
