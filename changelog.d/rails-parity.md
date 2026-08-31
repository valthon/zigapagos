### Added

- Rails presentation migration now writes typed, deterministic `parity[]`
  evidence for migrated pages, copied assets, signup/signin, denied and
  allowed mutations, and required-field validation. Nonempty handoffs also
  receive fixed `test/parity.ts` and `test/journey_playwright.py` runners;
  route facts stay in `MIGRATION.handoff.json`, never generated test logic.
- `tests/migrate/rails-presentation-parity.sh` builds the answered fixture,
  applies its checked-in schema to fresh isolated data directories, and
  replays the Bun contract twice plus the system-Chrome auth/form journey
  against the stock ZigBase release. This completes the presentation work in
  #167; Turbo Stream parity remains the separate #189 follow-up.

### Changed

- The pinned stock ZigBase release is v0.13.0, the first release providing
  the declarative `schema apply` surface required by migration replay. The
  download is still opt-in for `e2e`, SHA256-verified, and shared by the CLI,
  installer, npm package derivation, cache locator, and documentation.

### Known limitations

- `RAILS_ORIGIN` is an optional copied-asset oracle, not a live source-app
  requirement; the repository fixture deliberately does not boot Rails.
  Turbo Streams and Vue roots remain blocked rather than approximated.
- Parity runners verify observable presentation and API responses. They do
  not move authorization into browser code: ZigBase collection/consumer
  rules remain the enforcement boundary.
