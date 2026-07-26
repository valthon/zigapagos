// @ts-nocheck — intentionally imports a non-installed third-party package as a
// lint fixture. The import-scanner reads this file as TEXT, so @ts-nocheck only
// stops `tsc --noEmit` erroring on the missing module (the import line stays).
import { useState } from "@z/runtime";
import confetti from "canvas-confetti"; // FORBIDDEN: third-party npm
export interface Props {}
export default function Bad(_: Props) {
  const [n] = useState(0);
  confetti();
  void import("lodash"); // FORBIDDEN: dynamic third-party import
  return <span>{n}</span>;
}
