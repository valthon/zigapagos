### Internal

- Release CI now warms the exact pinned `translate-c` packages from Zig's official
  GitHub archive before resolving the dependency graph. This avoids persistent
  Codeberg protocol failures on GitHub-hosted runners; content hashes and a
  resolved-graph gate ensure the mirror cannot silently supply different or stale
  dependency bytes. Only dependency fetching is retried, while compilation runs once.
