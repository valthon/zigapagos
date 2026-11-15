### Fixed

- Migration detection reads framework names only from package dependency keys, ignoring keywords, scripts, and values. Malformed package JSON declares no dependencies and failed detection explains that behavior (#259).
- Hugo migration recognizes `config/_default/{hugo,config}.{toml,yaml,yml,json}` without a root config (#252, part 2).
