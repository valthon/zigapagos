import { useState } from "@z/runtime";
import { Button } from "../design-system/Button";

export default function Preference() {
  const [saved, setSaved] = useState(false);
  return (
    <section class="card">
      <span class="symbol" aria-hidden="true">𝒜</span>
      <h2>A component you can reuse</h2>
      <Button pressed={saved} onClick={() => setSaved(!saved)}>Save preference</Button>
      <p role="status">{saved ? "Preference saved" : "No preference saved"}</p>
    </section>
  );
}
