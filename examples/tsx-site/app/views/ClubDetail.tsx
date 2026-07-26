import { useParams, isServer } from "@z/runtime";
export default function ClubDetail() {
  const { id } = useParams<{ id: string }>();
  if (isServer()) return <section data-view="club-skeleton"><p>Loading club…</p></section>;
  return <section data-view="club" data-id={id}><h1>Club {id}</h1></section>;
}
