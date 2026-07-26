// Neutral loading state shown (SSR + first client render) until the Heavy chunk
// loads. Carries none of the heavy view's content.
export default function HeavySkeleton() {
  return <section data-view="heavy-skeleton"><p>Loading…</p></section>;
}
