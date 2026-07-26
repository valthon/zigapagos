interface Props {
  siteKey: string;
  onChange: (token: string) => void;
}

// A transitive child of ContactForm. It is never used with a client:* directive
// anywhere, so `zigapagos migrate` must NOT flag it as an island, and its `onChange`
// callback must never be emitted as an island prop.
export default function Recaptcha({ siteKey, onChange }: Props) {
  return <div className="g-recaptcha" data-sitekey={siteKey} data-callback={onChange} />;
}
