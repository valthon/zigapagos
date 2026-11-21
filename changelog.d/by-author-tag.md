### Added

- `$page.subpagesByAuthor(name)` and `$page.subpagesByTag(tag)` return indexed arrays of a section's active subpages in descending date order. Lookups are local to the section's language variant, return an empty array for missing keys, and cover the whole section on pagination pages.
