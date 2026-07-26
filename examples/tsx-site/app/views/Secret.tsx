// The gated view. Its distinctive `data-gated="secret"` marker (and the
// TOP SECRET text) must NEVER appear in a prerendered shell nor flash on
// screen before the route guard authorizes the visitor.
export default function Secret() {
  return (
    <section data-view="secret" data-gated="secret">
      <h1>Members area</h1>
      <p>TOP SECRET MEMBER DATA</p>
    </section>
  );
}
