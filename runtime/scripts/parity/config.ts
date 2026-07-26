import { readFileSync } from "node:fs";

export interface ParityConfig {
  reference: { kind: "static-dir"; path: string };
  build: { outDir: string };
  routes: { path: string }[];
  classHashPattern?: string;
}

export function routeToFile(route: string): string {
  const r = route.replace(/^\/+/, "").replace(/\/+$/, "");
  return r === "" ? "index.html" : `${r}/index.html`;
}

export function loadConfig(file: string): ParityConfig {
  const cfg = JSON.parse(readFileSync(file, "utf8")) as ParityConfig;
  if (!cfg.reference || !cfg.build || !Array.isArray(cfg.routes)) {
    throw new Error(`parity: invalid config ${file} (needs reference, build, routes)`);
  }
  return cfg;
}
