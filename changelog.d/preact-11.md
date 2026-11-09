### Removed

- Remove `SuspenseList` from `@z/runtime/compat` and the shared browser bundle,
  matching its removal in Preact 11. Callers must remove those imports; ordinary
  `Suspense` remains available.
