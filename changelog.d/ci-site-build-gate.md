### Changed

- CI builds `site/` on the pull-request path (new `site` job in `ci.yml`), running the four
  assertions — `build.sh`, `docs-mirror.sh`, `links.sh`, `js-budget.sh` — that previously ran
  only as deploy gates in `pages.yml` and in the scheduled `browser-e2e.yml`. It reuses the
  `zigapagos` binary the `build-binary` job already publishes, so nothing compiles.
