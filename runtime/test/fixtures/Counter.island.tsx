import { useState } from "@z/runtime/core";

export interface Props { start?: number; label: string }

export default function Counter({ start = 0, label }: Props) {
  const [n, setN] = useState(start);
  return (
    <button onClick={() => setN(n + 1)}>{label}: {n}</button>
  );
}
