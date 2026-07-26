import Recaptcha from "./Recaptcha.tsx";

interface Props {
  endpoint: string;
  theme: ThemeConfig;
  onSuccess: (id: string) => void;
}

// A real island (used as <ContactForm client:load …>). It renders Recaptcha
// as a plain child WITHOUT a client:* directive, so Recaptcha is NOT itself an
// island — it is part of ContactForm.
export default function ContactForm({ endpoint, theme, onSuccess }: Props) {
  return (
    <form action={endpoint} data-theme={theme.name}>
      <input name="email" type="email" />
      <Recaptcha siteKey="abc123" onChange={(t) => console.log(t)} />
      <button type="submit" onClick={() => onSuccess("ok")}>Send</button>
    </form>
  );
}
