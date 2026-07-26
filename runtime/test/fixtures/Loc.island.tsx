import { host } from "@z/runtime/host";
export interface Props {}
export default function Loc(_: Props) {
  return <p>path: {host.pathname()}</p>;
}
