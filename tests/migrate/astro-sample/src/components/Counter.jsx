import { useState } from "react";

// A classic interactive island. Used as <Counter client:visible …>.
export default function Counter({ start = 0, label }) {
  const [n, setN] = useState(start);
  return (
    <button onClick={() => setN(n + 1)}>
      {label}: {n}
    </button>
  );
}
