import type { ResolvedState as Gen } from "./types.ts";
import type { ResolvedState as Runtime } from "../../runtime/src/flags.ts";
// Structural identity: each must be assignable to the other. If ZigBase changes
// the envelope, regen changes Gen and one of these fails `tsc --noEmit`.
const _a: Gen = {} as Runtime;
const _b: Runtime = {} as Gen;
void _a; void _b;
