import { FlagsProvider, useFlag } from "@z/runtime/compat";
export interface Props { label: string }
function Inner({ label }: Props) { return <span>{useFlag("demo") ? `${label}!` : label}</span>; }
export default function Flagged(props: Props) { return <FlagsProvider><Inner {...props} /></FlagsProvider>; }
