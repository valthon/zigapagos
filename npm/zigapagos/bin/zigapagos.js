#!/usr/bin/env node
"use strict";
// The bare `zigapagos` package is an ALIAS for `@zigapagos/cli`, so that
// `npx zigapagos` works and the unscoped name is not squatted by someone else.
// It carries no resolver and no platform packages of its own: it depends on
// `@zigapagos/cli` at the exact same version and re-enters its launcher, which
// is what owns platform resolution.
//
// `process.argv` is untouched by the hand-off — argv[1] is this file rather than
// the real launcher, and the launcher slices from argv[2] — so arguments and exit
// status behave identically through either package. Requiring the launcher runs
// it (its work is top-level, not exported), which is the whole hand-off.
require("@zigapagos/cli/bin/zigapagos.js");
