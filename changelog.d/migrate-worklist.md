### Fixed

- Migration worklists name unconverted Hugo, Jekyll, and Eleventy content outside conventional roots and Next.js/Gatsby/Nuxt content-layer Markdown/MDX, with explicit reasons and sorted paths. A repeat run never lists its own report, including a custom `--output` inside the source tree, while unrelated source files named `MIGRATION.md` stay listed (#254, #261).
- Nuxt inventory includes Nuxt 4 `app/pages`, `app/layouts`, `app/components`, and root, `src/`, and `app/` application entry files (#260).
