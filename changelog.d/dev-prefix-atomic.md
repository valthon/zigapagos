### Fixed

- Prefixed `dev` and `e2e` servers now publish fully staged trees with a directory swap, so a refresh cannot expose a partially copied site; a staging failure after the server starts also tears the child server down.
