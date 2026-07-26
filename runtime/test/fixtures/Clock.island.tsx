import { host } from "@z/runtime/host";
export interface Props {}
// host.now() is 0 on the server branch, Date.now() on the client → a real SSR/hydration
// mismatch unless the clock is frozen on both sides.
export default function Clock(_: Props) {
  return <time>{String(host.now())}</time>;
}
