### Changed

- Island props checking now fails builds by default. Use `--island-props-check=warn|off` explicitly to relax it.
- Components without a `client:*` directive render server-only; deferred island modules are fetched when their trigger fires.

### Fixed

- Props checks use the runtime's installed compiler, support sites without a tsconfig, and run without Node.
- Default-on checking also applies to the native build API. Project TypeScript JSX, module and target options retain precedence over fallback defaults.
