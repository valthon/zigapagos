### Fixed

- Rails layout forms and controls, including layout-rendered partials, now participate in explicit backend bindings.

### Added

- Rails structural Stimulus ports support nested controllers, standard keyboard filters, global event targets, and native listener options. The generated helper scopes targets/actions to their controller and removes global listeners on teardown. Controller method bodies still require manual porting.
