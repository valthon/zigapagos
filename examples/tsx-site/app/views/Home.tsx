import { Link } from "@z/runtime";
export default function Home() {
  return <section data-view="home"><h1>Home</h1><Link href="/booking" data-nav="booking">Book</Link><Link href="/club/42" data-nav="club">Club 42</Link><Link href="/secret" data-nav="secret">Members</Link><Link href="/dash/overview" data-nav="dash">Dashboard</Link></section>;
}
