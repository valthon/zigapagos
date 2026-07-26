import { useState } from "@z/runtime";

export interface Props {
  start?: number;
}

export default function Counter({ start = 0 }: Props) {
  const [n, setN] = useState(start);
  return (
    <button class="demo-counter" onClick={() => setN(n + 1)}>
      {n === 0 ? "This button hydrated — click me" : `Clicked ${n} time${n === 1 ? "" : "s"}`}
    </button>
  );
}
