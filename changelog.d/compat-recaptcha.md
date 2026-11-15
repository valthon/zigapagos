### Fixed

- Compat `ReCAPTCHA` clears solved tokens on widget errors, supports `onErrored` and `onExpired`, and passes size, theme and tabindex to Google when supplied. `useRecaptcha` now clears tokens on expiry and error too. Migration guidance describes the supported props and remaining limitations (#264).
