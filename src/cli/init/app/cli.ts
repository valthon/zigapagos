import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const command = process.argv[2];
if (command !== "release" && command !== "dev") throw new Error("Use bun run build or bun run dev");
const project = fileURLToPath(new URL("../", import.meta.url));
const runtime = realpathSync(new URL("../node_modules/@z/runtime", import.meta.url));
const child = Bun.spawn([
  process.env.ZIGAPAGOS_BIN || "zigapagos", command,
  ...(command === "release" ? ["--spa=app/app.spa.tsx|/app", "--force", "--output=public"] : []),
  ...process.argv.slice(3),
], { cwd: project, env: { ...process.env, ZIGAPAGOS_RUNTIME_DIR: runtime }, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
process.exit(await child.exited);
