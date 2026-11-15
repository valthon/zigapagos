### Fixed

- Relative page aliases no longer read freed path components when the path table grows, preventing intermittent build panics or incorrect output URLs. Aliases and alternative outputs now share reservation-safe prefix handling.
