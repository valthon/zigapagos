### Changed

- Upgrade the shared runtime to Preact 11.2.0. The React compatibility bridge now
  exports `use` and `useEffectEvent`; `use(promise)` cannot be prerendered, so
  during SSR use it only with a context. Router subscriptions, pending guards,
  lazy route loads, viewport prefetch observers, and reload-state listeners
  retain synchronous unmount protection despite Preact 11's deferred
  passive-effect cleanup.
- Function components now receive `ref` in props, so a component that spreads its
  props onto an element, such as `function Field(props) { return <input {...props} />; }`,
  puts a caller's ref on that element rather than on the component.
- The compatibility bridge's `version` changes from `18.3.1` to `19.0.0`, which
  changes the branch taken by npm React libraries that detect the version.

### Added

- `Link` passes a caller's `ref` to its anchor element. Object refs, callback
  refs, and callback refs that return a cleanup are all supported.

### Fixed

- Viewport prefetch ignores intersection notifications delivered after a Link
  unmounts or its observation has already triggered a prefetch, and prefetches
  against the current route table after the Router's `routes` change.
- A lazy route chunk that fails after its Router has unmounted or navigated away
  no longer leaves the route stuck on its skeleton on the next visit.

### Removed

- Remove `SuspenseList` from `@z/runtime/compat` and the shared browser bundle,
  matching its removal in Preact 11. Callers must remove those imports; ordinary
  `Suspense` remains available.
