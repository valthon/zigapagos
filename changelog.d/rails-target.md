### Added

- `zigapagos migrate <rails-app> --target DIR` now works for Rails sources, writing both discovery artifacts — `DIR/MIGRATION.md` and `DIR/MIGRATION.manifest.json` — into a missing or empty directory. It reuses the same nested/non-empty guards the eight other sources already use, and the manifest it writes is byte-identical to the same app's `-o` run.
- `docs/migration/rails-to-zigapagos.md`: a deterministic reference for reading a Rails discovery result — what each of the six classifications asserts, what `unresolved` obliges a human to do per rule, and which fields carry claims the manifest deliberately does not make. Mirrored byte-for-byte into `skills/zigapagos-rails-migration/references/` so the skill is self-contained when installed into a consumer project, with `tests/skills/sync.sh` extended to gate both skills against drift.
- A second Rails fixture app (`tests/migrate/rails-legacy-assets/`) covering the Sprockets asset pipeline end to end. The Sprockets branch of the asset resolver had unit tests but no fixture — the only `sprockets` string in the fixture tree was a commented-out gem — so the path that reads a real compiled Sprockets manifest had never executed against a real app.

### Changed

- **Rails' `--target` writes the discovery artifacts and nothing else.** Two sibling fragments earlier in this same release (`rails-classify.md`, `rails-manifest.md`) described a future `--target` assembling a target directory with "content conversion, island scaffolding, asset copying", the way `--target` does for the other eight sources — that is not what shipped, so both fragments were corrected alongside this one rather than left to publish a contradiction. The difference is deliberate rather than deferred: Rails discovery converts nothing by design, and converting a Rails presentation layer is issue #167. The flag's help text states this directly, rather than a conversion step being invented to justify the earlier description.

### Known limitations

- Discovery and classification are complete; **conversion has not started**. A manifest tells you what you are dealing with — which routes are safely static, which are backend responsibilities, which redirect, and which cannot be settled without executing Rails — and nothing in this release turns any of that into zigapagos content. That is #167.
- `spa` is still assigned to nothing. Proving a component root owns routing needs module and import resolution that discovery does not do; the classification exists because the manifest schema declares it, and a test pins that nothing returns it.
