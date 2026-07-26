// Gated child of the guarded /members layout. Its data-gated marker must never
// appear in the prerendered shell nor flash before the guard authorizes.
export default function MembersProfile() {
  return <section data-view="members-profile" data-gated="member"><p>MEMBER PROFILE</p></section>;
}
