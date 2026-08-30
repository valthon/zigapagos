### Added

- `zigapagos migrate <rails-app> --target DIR` now works for Rails sources, writing both discovery artifacts — `DIR/MIGRATION.md` and `DIR/MIGRATION.manifest.json` — into a missing or empty directory. It reuses the same nested/non-empty guards the eight other sources already use, and the manifest it writes is byte-identical to the same app's `-o` run. (Later in this same release, `--target` also assembles the converted project — see the `rails-convert` entries.)
- `docs/migration/rails-to-zigapagos.md`: a deterministic reference for reading a Rails discovery result — what each of the six classifications asserts, what `unresolved` obliges a human to do per rule, and which fields carry claims the manifest deliberately does not make. Mirrored byte-for-byte into `skills/zigapagos-rails-migration/references/` so the skill is self-contained when installed into a consumer project, with `tests/skills/sync.sh` extended to gate both skills against drift.
- A second Rails fixture app (`tests/migrate/rails-legacy-assets/`) covering the Sprockets asset pipeline end to end. The Sprockets branch of the asset resolver had unit tests but no fixture — the only `sprockets` string in the fixture tree was a commented-out gem — so the path that reads a real compiled Sprockets manifest had never executed against a real app.

### Changed

- **Rails' `--target` was, at this point in the release, the discovery artifacts and nothing else.** Two sibling fragments earlier in this same release (`rails-classify.md`, `rails-manifest.md`) described a `--target` assembling a target directory with "content conversion, island scaffolding, asset copying", the way `--target` does for the other eight sources; that is not what this change shipped, so both fragments were corrected alongside it rather than left to publish a contradiction. The conversion landed later in the same release (`rails-convert.md`), and those three fragments have been reconciled again against what actually ships.

### Known limitations

- `spa` is still assigned to nothing **as a classification**. Proving a component root owns routing needs module and import resolution that discovery does not do; the value exists because the manifest schema declares it, and a test pins that nothing returns it. `spa` as a *decision choice* on a dynamic route is a different thing and does scaffold a `.spa.tsx` — see the `rails-convert` entries.
