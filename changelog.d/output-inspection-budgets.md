### Added

- `zigapagos inspect-output [DIR]` inventories emitted HTML/CSS/JS raw bytes,
  reports page script, island-module, and module-preload references, and accepts
  exact aggregate byte budgets with deterministic text or NDJSON reports.
  Inline script markup, external resources, unresolved references, and lazy
  chunks have explicit measurement boundaries. Site CI now exercises aggregate
  budgets alongside its separate directly referenced landing-page JS gate.
