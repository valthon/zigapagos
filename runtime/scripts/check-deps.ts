import pkg from "../package.json";
const allowed = ["preact", "preact-render-to-string"].sort();
const actual = Object.keys(pkg.dependencies ?? {}).sort();
if (JSON.stringify(actual) !== JSON.stringify(allowed)) {
  console.error(`runtime dependencies must be exactly ${allowed.join(", ")}; got: ${actual.join(", ") || "(none)"}`);
  process.exit(1);
}
console.log("deps OK:", actual.join(", "));
