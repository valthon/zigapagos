### Added

- `zigapagos migrate <source> --target <new-site>` now assembles a minimal valid Zigapagos project by composing each framework adapter's deterministic content, React-island, and fixed-URL asset transforms. It refuses non-empty or source-nested targets and leaves semantic framework behavior explicit in the generated `MIGRATION.md`.
