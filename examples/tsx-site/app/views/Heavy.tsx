// A "heavy" view that is code-split into its own chunk via `lazy()` in
// app.spa.tsx. Its distinctive marker (HEAVY-CHUNK-MARKER) must NOT appear in
// the entry bundle — only in the separately-loaded chunk — and must not be in
// the prerendered shell (the shell shows HeavySkeleton until the chunk loads).
export default function Heavy() {
  return (
    <section data-view="heavy" data-heavy="loaded">
      <h1>Heavy view</h1>
      <p>HEAVY-CHUNK-MARKER — this code lives in its own chunk.</p>
    </section>
  );
}
