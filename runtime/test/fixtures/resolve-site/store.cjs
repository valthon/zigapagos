// A CJS consumer in the bridged graph — the use-sync-external-store shape:
// require("react") must hit the resolve override SYNCHRONOUSLY (an async
// module override dies here with "require() async module is unsupported").
const react = require("react");
module.exports = {
  cjsReact: typeof react.useState === "function" ? "cjs-react-ok" : "cjs-react-broken",
};
