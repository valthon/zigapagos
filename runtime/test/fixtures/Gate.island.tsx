import { useFlag } from "@z/runtime";
export interface Props {}
export default function Gate(_: Props) {
  const canBook = useFlag("canBook");
  return <div>{canBook ? <a href="/booking">Book</a> : <span>soon</span>}</div>;
}
