### Fixed

- Emit the final table-of-contents list-item closing tag explicitly. Browsers
  already accept its omission; static HTML parsers can now inspect the complete
  outline without reporting a missing end tag. Empty outlines stay empty.
