// An island that renders a component from an opt-in npm-compat package
// (@demo/widget). @demo/widget imports React from the bare `react` specifier;
// the bridge (z-runtime.config.json `npmCompat`) keeps that import external and
// the page import-map resolves it to the shared runtime => ONE Preact. Allowed
// by the linter because @demo/widget is declared under `islandImports.npmCompat`.
import { Widget } from "@demo/widget";
export interface Props { label: string }
export default function WidgetIsland({ label }: Props) {
  return <Widget label={label} />;
}
