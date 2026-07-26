// Ungated redirect target for the guard. Reachable by anyone; carries no
// gated content.
export default function Login() {
  return (
    <section data-view="login">
      <h1>Sign in</h1>
      <p>Please sign in to view the members area.</p>
    </section>
  );
}
