import { useFlag } from "@z/runtime";

// Dogfoods the baked flag defaults: `bookAsGuest` is declared
// default-ON in app.spa.tsx's `spa.flags`, so this marker renders "on" in the
// prerendered shell AND on the very first client render — never a
// false-while-loading "off" flash. spa_flags.sh + spa_playwright.py assert it.
export default function Booking() {
  const guest = useFlag("bookAsGuest");
  return (
    <section data-view="booking" data-guest-booking={guest ? "on" : "off"}>
      <h1>Booking</h1>
      {guest && <p data-guest-cta>Book as guest</p>}
    </section>
  );
}
