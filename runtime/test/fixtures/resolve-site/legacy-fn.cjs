// `module.exports = function` — the CJS shape a bare `{ ...ns }` spread would
// destroy (spreading a function yields `{}`). The override must synthesize
// `default` so `import legacy from "@acme/legacy"` gets the callable.
module.exports = function legacy() {
  return "legacy-fn-ok";
};
