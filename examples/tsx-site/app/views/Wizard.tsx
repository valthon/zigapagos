import { useRestorableState } from "@z/runtime";

// A tiny multi-step form that exercises state-preserving dev reload: the text
// field and the step counter both live in useRestorableState, so a full-page
// `zigapagos serve` reload restores their in-memory state instead of wiping it. In
// production (no dev livereload client) the hook behaves exactly like useState.
export default function Wizard() {
  const [name, setName] = useRestorableState<string>("wizard-name", "");
  const [step, setStep] = useRestorableState<number>("wizard-step", 1);
  return (
    <section data-view="wizard">
      <h1>Wizard</h1>
      <p data-wizard-step>Step {step}</p>
      <input data-restore-field value={name} onInput={(e) => setName(e.currentTarget.value)} />
      <button data-wizard-next onClick={() => setStep(step + 1)}>Next</button>
    </section>
  );
}
