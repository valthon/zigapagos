// Neutral loading UI held on screen (and prerendered into the gated route's
// shell) while a guard is pending. Brand + spinner text only — zero gated
// content, so it is safe to serve statically to anyone.
export default function GuardFallback() {
  return (
    <section data-view="guard-fallback">
      <p>pilot-site — checking access…</p>
    </section>
  );
}
