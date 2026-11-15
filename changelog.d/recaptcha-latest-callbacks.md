### Fixed

- Compat `ReCAPTCHA` uses the latest `onChange`, `onExpired`, and `onErrored` handlers after a parent rerenders with the same `siteKey`, including handlers added or removed after mount. Refs #264.
