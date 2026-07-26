import { useState } from "@z/runtime";
export interface Props { headline: string }
export default function Hero({ headline }: Props) {
  const [open, setOpen] = useState(false);
  return <section><h1>{headline}</h1><button onClick={() => setOpen(!open)}>{open ? "−" : "+"}</button></section>;
}
