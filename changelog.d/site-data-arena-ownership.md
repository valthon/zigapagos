### Fixed

- Release cleanup now frees site data through its owning arena. Sites with
  `.ziggy` data no longer crash with an invalid free in single-threaded Debug
  builds. CI executes a real site-data release with the Debug allocator, in
  addition to the existing single-threaded compile checks.
