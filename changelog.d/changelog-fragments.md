### Internal

- Changelog entries are now recorded as one fragment file per change in `changelog.d/`,
  assembled into a version section by `scripts/assemble-changelog.sh` at release, so
  parallel pull requests never conflict on `CHANGELOG.md`. See `changelog.d/README.md`.
