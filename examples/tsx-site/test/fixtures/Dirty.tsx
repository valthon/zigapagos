import { useState, useId } from "react";
import ReCAPTCHA from "react-google-recaptcha";
export default function Dirty() { const [x] = useState(0); const id = useId(); return <div id={id}>{x}</div>; }
