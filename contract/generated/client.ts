import { host } from "@z/runtime/host";
import type { ClubAuthRequest, ClubSession, ContactRequest, ContactResponse, ResolvedState } from "./types.ts";

export const FLAGS_URL = "/api/flags/state";
export function primeFlags(): void { host.fetchShared(FLAGS_URL, "flags"); }
export function readFlags(): ResolvedState { return host.store.getJson<ResolvedState>("flags"); }

function assertContactResponse(x: any): void {
  if (typeof x?.ok !== "boolean") throw new Error("contract violation: ContactResponse.ok must be boolean");
  if (x?.errors !== undefined && !Array.isArray(x?.errors)) throw new Error("contract violation: ContactResponse.errors must be array");
}

function assertClubSession(x: any): void {
  if (typeof x?.token !== "string") throw new Error("contract violation: ClubSession.token must be string");
  if (typeof x?.expiresAt !== "string") throw new Error("contract violation: ClubSession.expiresAt must be string");
  if (x?.member !== undefined && (typeof x?.member !== "object" || x?.member === null || Array.isArray(x?.member))) throw new Error("contract violation: ClubSession.member must be object");
}

export async function postContact(req: ContactRequest): Promise<ContactResponse> {
  const env = await host.fetchOpts({ url: "/api/contact", method: "POST", headers: [{ name: "content-type", value: "application/json" }], body: JSON.stringify(req) });
  if (env.status === 0) throw new Error("postContact: network error");
  const out = JSON.parse(env.body) as ContactResponse;
  assertContactResponse(out);
  return out;
}

export async function postClubLogin(req: ClubAuthRequest): Promise<ClubSession> {
  const env = await host.fetchOpts({ url: "/api/club/login", method: "POST", headers: [{ name: "content-type", value: "application/json" }], body: JSON.stringify(req) });
  if (env.status === 0) throw new Error("postClubLogin: network error");
  const out = JSON.parse(env.body) as ClubSession;
  assertClubSession(out);
  return out;
}
