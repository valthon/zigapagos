### Added

- Rails presentation migration now ports explicitly answered Stimulus
  controller elements, Turbo frames, and literal-props React roots into real
  islands. Stimulus ports wire targets, values, classes, and supported action
  descriptors while quoting untranslated method bodies as visible TODOs;
  source-less frames can be preserved with `inline`; React sources and their
  relative import closure are copied unchanged through the runtime bridge.
- Portable `RAILS_REQUEST_TIME_STATE` ivar regions now accept `island` or
  `backend` and become record-backed data islands. List regions call the
  backend collection's list operation; dynamic record routes apply a second
  answer after `spa` and render `getOne(params.id)` through the SPA view.
  This closes #184.
- Generated SPAs recover deterministic stylesheet links from the Rails layout
  into `spa.head`, so their shells no longer start unstyled. This closes #180.
- `RAILS_STIMULUS_CONTROLLER`, `RAILS_COMPONENT_PROPS_DYNAMIC`,
  `RAILS_COMPONENT_VUE_UNSUPPORTED`, and `RAILS_JS_ENTRY` make the new
  boundaries explicit. Turbo Streams remain `retain`/`blocked` and point to
  follow-up #189.

### Changed

- A dynamic React mount is now `RAILS_COMPONENT_PROPS_DYNAMIC` instead of the
  literal-root shape: request-time Ruby props are never serialized by guess.
- Decision ranking treats `backend` as a producing answer when the ivar body
  port has proved it can emit the data island.
- Generated TypeScript enables `allowJs`, `allowImportingTsExtensions`, and
  `noEmit` so copied `.js`/`.jsx` components and explicit TypeScript imports
  are checked in the same target.
- Turbo Drive data attributes and reviewed Rails JavaScript entries are
  dropped because ordinary navigation and the generated island runtime own
  those roles in the target.

### Known limitations

- Stimulus conversion is structural, not method transpilation; nested
  controllers, unsupported descriptor options, regex-sensitive lexical
  shapes, and raw-text action elements require hand work.
- React `require()` and dynamic imports are not bundled. A frame island still
  needs its same-origin `src` proxied to Rails until equivalent fragment HTML
  is served by the migrated site.
- Wrapping islands do not settle findings inside their slots. Turbo Streams
  and Vue roots remain acknowledgeable rather than silently approximated.
