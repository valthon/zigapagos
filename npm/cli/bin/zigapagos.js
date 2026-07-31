#!/usr/bin/env node
"use strict";
// The `zigapagos` launcher: resolve the platform binary, exec it with our argv,
// and exit with its status. Everything the CLI does is the binary's business —
// this shim must add no behaviour of its own beyond the three failure modes
// below, because it sits in front of a build tool whose output gets parsed.
const { execFileSync } = require("node:child_process");
const { constants } = require("node:os");
const { binaryPath, childEnv } = require("../index.js");

try {
  // `childEnv` adds the two things this package installs but the binary cannot
  // find on its own: the bundled runtime tree (ZIGAPAGOS_RUNTIME_DIR) and our
  // node_modules/.bin on PATH, so bun and zigbase resolve however zigapagos was
  // invoked. Both are additive — see index.js.
  execFileSync(binaryPath(), process.argv.slice(2), { stdio: "inherit", env: childEnv() });
} catch (err) {
  // 1) The child ran and failed: its exit code is the only thing we report.
  if (typeof err.status === "number") process.exit(err.status);

  // 2) The child was killed by a signal. Silent by design: Ctrl-C is how a dev
  //    server is stopped, and with `stdio: "inherit"` the whole foreground
  //    process group gets the SIGINT, so printing here would put an error on
  //    every normal shutdown. 128+signo is the shell convention.
  if (err.signal) {
    const signo = constants.signals[err.signal];
    process.exit(typeof signo === "number" ? 128 + signo : 1);
  }

  // 3) Resolver/spawn failure. index.js already phrases both of its own errors
  //    (unsupported platform, missing optionalDependency) for a human reading a
  //    terminal, so this adds nothing to them beyond dropping the stack trace.
  console.error(err.message || String(err));
  process.exit(1);
}
