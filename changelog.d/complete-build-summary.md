### Fixed

- Bundle caches and host inventories stay under the discovered site root when invoked from a child directory.
- Build summaries include the host configuration and sitemap written after the core rendering pass, excluding preserved files that this build did not emit.
- Summary report files also work when invoking a clean project build from a child directory.
