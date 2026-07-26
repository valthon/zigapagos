import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { emitTypes, tsTypeOf, emitClient, emitAssert } from "./apigen.ts";

test("tsTypeOf maps scalars, arrays, additionalProperties maps, enum unions", () => {
  expect(tsTypeOf({ type: "string" })).toBe("string");
  expect(tsTypeOf({ type: "boolean" })).toBe("boolean");
  expect(tsTypeOf({ type: "array", items: { type: "string" } })).toBe("string[]");
  expect(tsTypeOf({ type: "object", additionalProperties: { type: "boolean" } })).toBe("Record<string, boolean>");
  expect(tsTypeOf({ type: "string", enum: ["a", "b"] })).toBe('"a" | "b"');
});

test("emitTypes emits ResolvedState identical to the runtime canary + CONTRACT_VERSION", () => {
  const doc = {
    "x-zigbase-contract-version": "2026-06-27.1",
    components: { schemas: {
      ResolvedState: { type: "object", required: ["flags", "experiments"], properties: {
        flags: { type: "object", additionalProperties: { type: "boolean" } },
        experiments: { type: "object", additionalProperties: { type: "string" } },
      } },
      ContactResponse: { type: "object", required: ["ok"], properties: {
        ok: { type: "boolean" }, errors: { type: "array", items: { type: "string" } },
      } },
    } },
  };
  const ts = emitTypes(doc);
  expect(ts).toContain("export interface ResolvedState {");
  expect(ts).toContain("flags: Record<string, boolean>;");
  expect(ts).toContain("experiments: Record<string, string>;");
  expect(ts).toContain("ok: boolean;");
  expect(ts).toContain("errors?: string[];"); // optional (not in required)
  expect(ts).toContain('export const CONTRACT_VERSION = "2026-06-27.1";');
});

test("emitTypes fails loud on unsupported constructs", () => {
  expect(() => emitTypes({ components: { schemas: { X: { oneOf: [] } } } })).toThrow(/unsupported/i);
});

test("real contract: ResolvedState flags/experiments are non-optional Records", () => {
  const contractPath = resolve(import.meta.dir, "../../contract/zigbase.openapi.json");
  const doc = JSON.parse(readFileSync(contractPath, "utf8"));
  const ts = emitTypes(doc);
  // Both properties are in required[], so no "?" — non-optional
  expect(ts).toContain("flags: Record<string, boolean>;");
  expect(ts).toContain("experiments: Record<string, string>;");
});

test("emitClient imports host (never Preact) + emits typed primeFlags/readFlags/postContact", () => {
  const doc = { components: { schemas: {
    ResolvedState: { type: "object", required: ["flags","experiments"], properties: { flags: {type:"object",additionalProperties:{type:"boolean"}}, experiments: {type:"object",additionalProperties:{type:"string"}} } },
    ContactRequest: { type:"object", required:["name"], properties: { name: {type:"string"} } },
    ContactResponse: { type:"object", required:["ok"], properties: { ok: {type:"boolean"} } },
  } }, paths: {
    "/api/flags/state": { get: { responses: { "200": { $ref: "#/components/schemas/ResolvedState" } } } },
    "/api/contact": { post: { requestBody: { $ref:"#/components/schemas/ContactRequest" }, responses: { "200": { $ref:"#/components/schemas/ContactResponse" } } } },
  } };
  const ts = emitClient(doc);
  expect(ts).toContain('import { host } from "@z/runtime/host";');
  expect(ts).not.toMatch(/from ["']preact/);          // never Preact
  expect(ts).not.toMatch(/from ["']@z\/runtime["']/);  // never bare @z/runtime
  expect(ts).toContain("export function readFlags(): ResolvedState");
  expect(ts).toContain("export async function postContact(req: ContactRequest): Promise<ContactResponse>");
  expect(ts).toContain("host.fetchOpts");
  expect(ts).toContain("if (env.status === 0) throw");
});

test("emitAssert emits bidirectional ResolvedState type-check", () => {
  const ts = emitAssert();
  expect(ts).toContain('import type { ResolvedState as Gen } from "./types.ts";');
  expect(ts).toContain('import type { ResolvedState as Runtime } from "../../runtime/src/flags.ts";');
  expect(ts).toContain("const _a: Gen = {} as Runtime;");
  expect(ts).toContain("const _b: Runtime = {} as Gen;");
});

// ---------------------------------------------------------------------------
// validators option tests
// ---------------------------------------------------------------------------

const validatorDoc = {
  components: {
    schemas: {
      ContactRequest: { type: "object", required: ["name"], properties: { name: { type: "string" } } },
      ContactResponse: { type: "object", required: ["ok"], properties: {
        ok: { type: "boolean" },
        errors: { type: "array", items: { type: "string" } },
      } },
      ClubAuthRequest: { type: "object", required: ["email"], properties: { email: { type: "string" } } },
      ClubSession: { type: "object", required: ["token", "expiresAt"], properties: {
        token: { type: "string" },
        expiresAt: { type: "string" },
        member: { type: "object", additionalProperties: { type: "string" } },
      } },
    },
  },
  paths: {
    "/api/contact": { post: { requestBody: { $ref: "#/components/schemas/ContactRequest" }, responses: { "200": { $ref: "#/components/schemas/ContactResponse" } } } },
    "/api/club/login": { post: { requestBody: { $ref: "#/components/schemas/ClubAuthRequest" }, responses: { "200": { $ref: "#/components/schemas/ClubSession" } } } },
  },
};

test("emitClient validators:post emits assertContactResponse with required-field throw", () => {
  const ts = emitClient(validatorDoc, { validators: "post" });
  // assert function is emitted
  expect(ts).toContain("function assertContactResponse(");
  // required field 'ok' is checked
  expect(ts).toContain(".ok");
  // throws on mismatch
  expect(ts).toMatch(/throw new Error\("contract violation: ContactResponse\.ok/);
  // wrapper calls the assert
  expect(ts).toContain("assertContactResponse(");
  // optional 'errors' field gets a presence-guarded check (not a bare required check)
  expect(ts).toContain("errors !== undefined");
});

test("emitClient validators:post emits assertClubSession for second POST endpoint", () => {
  const ts = emitClient(validatorDoc, { validators: "post" });
  expect(ts).toContain("function assertClubSession(");
  expect(ts).toMatch(/throw new Error\("contract violation: ClubSession\.token/);
  expect(ts).toMatch(/throw new Error\("contract violation: ClubSession\.expiresAt/);
  // optional 'member' field (object) guarded by presence check
  expect(ts).toContain("member !== undefined");
  // wrapper calls the assert
  expect(ts).toContain("assertClubSession(");
});

test("emitClient validators:post wrapper uses out variable + assert + return", () => {
  const ts = emitClient(validatorDoc, { validators: "post" });
  expect(ts).toContain("const out = JSON.parse(env.body) as ContactResponse;");
  expect(ts).toContain("assertContactResponse(out);");
  expect(ts).toContain("return out;");
});

test("emitClient validators:none does NOT emit assert functions or calls", () => {
  const ts = emitClient(validatorDoc, { validators: "none" });
  expect(ts).not.toContain("function assertContactResponse");
  expect(ts).not.toContain("function assertClubSession");
  expect(ts).not.toContain("assertContactResponse(");
  expect(ts).not.toContain("assertClubSession(");
  // still returns parsed body directly (old style)
  expect(ts).toContain("return JSON.parse(env.body) as ContactResponse;");
});

test("emitClient validators:all behaves like post for POST endpoints", () => {
  const tsAll = emitClient(validatorDoc, { validators: "all" });
  const tsPost = emitClient(validatorDoc, { validators: "post" });
  // For v1, all === post (GET validators out of scope)
  expect(tsAll).toBe(tsPost);
});

test("emitClient default (no opts) is equivalent to validators:post", () => {
  const tsDefault = emitClient(validatorDoc);
  const tsPost = emitClient(validatorDoc, { validators: "post" });
  expect(tsDefault).toBe(tsPost);
});

// ---------------------------------------------------------------------------
// loud-fail: inline (non-$ref) schema guards
// ---------------------------------------------------------------------------

test("emitClient throws on inline POST response schema (not a $ref)", () => {
  // Only the response is inline — requestBody is a $ref to a known schema
  const doc = {
    components: { schemas: {
      Foo: { type: "object", required: ["bar"], properties: { bar: { type: "string" } } },
    } },
    paths: {
      "/api/x": {
        post: {
          requestBody: { $ref: "#/components/schemas/Foo" },
          responses: {
            "200": {
              content: {
                "application/json": {
                  schema: { type: "object", properties: {} },
                },
              },
            },
          },
        },
      },
    },
  };
  expect(() => emitClient(doc)).toThrow(/unsupported inline schema/i);
});

test("emitClient throws on inline POST requestBody schema (not a $ref)", () => {
  const doc = {
    components: { schemas: {
      FooResponse: { type: "object", required: ["ok"], properties: { ok: { type: "boolean" } } },
    } },
    paths: {
      "/api/y": {
        post: {
          requestBody: { content: { "application/json": { schema: { type: "object", properties: {} } } } },
          responses: { "200": { $ref: "#/components/schemas/FooResponse" } },
        },
      },
    },
  };
  expect(() => emitClient(doc)).toThrow(/unsupported inline schema/i);
});

test("emitClient throws on inline GET response schema (not a $ref)", () => {
  const doc = {
    components: { schemas: {} },
    paths: {
      "/api/z/state": {
        get: {
          responses: {
            "200": {
              content: {
                "application/json": {
                  schema: { type: "object", properties: {} },
                },
              },
            },
          },
        },
      },
    },
  };
  expect(() => emitClient(doc)).toThrow(/unsupported inline schema/i);
});

test("tsTypeOf throws on array without items", () => {
  expect(() => tsTypeOf({ type: "array" })).toThrow(/unsupported/i);
});

test("tsTypeOf throws on additionalProperties:true (boolean, not a schema object)", () => {
  expect(() => tsTypeOf({ type: "object", additionalProperties: true })).toThrow(/unsupported/i);
});
