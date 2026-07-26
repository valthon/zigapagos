// @ts-nocheck — intentionally imports non-installed packages as lint fixtures.
// The import-scanner reads this file as TEXT, so @ts-nocheck only stops
// `tsc --noEmit` erroring on the missing modules (the import lines stay).
import { FlagsProvider } from "@z/runtime/compat";
import { useCustomer } from "@myapp/shared/customer";  // firstParty (config)
import { useRoute } from "react-router-dom";           // npmCompat (config)
import ReCAPTCHA from "some-uninstalled-widget";       // NOT allowlisted
export interface Props {}
export default function X(_: Props) { return <div /> }
