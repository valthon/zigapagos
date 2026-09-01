### Fixed

- Rails presentation discovery now retains safe symlinked views and
  controllers, refuses controller symlink escapes, reports malformed or
  locale-mismatched translation documents, honors namespace helper-prefix
  overrides, and preserves deferred template shapes such as nested
  `fields_for`, block-form links, dynamic assets, and named-yield defaults as
  explicit migration facts instead of silent omissions.
