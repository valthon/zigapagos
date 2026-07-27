# Changelog fragments

A change that belongs in the changelog adds a small **fragment** file in this directory
instead of editing `CHANGELOG.md`. At release time `scripts/assemble-changelog.sh` folds
every fragment into a new version section in `CHANGELOG.md` and deletes the fragments it
consumed.

This exists for one reason: **parallel pull requests must not conflict on `CHANGELOG.md`.**
Two PRs each adding their own `changelog.d/<slug>.md` merge cleanly; two PRs each appending
a bullet to a shared `## [Unreleased]` block collide on the same lines and one of them has
to be rebased by hand. This repository is developed with several branches open at once, so
that cost is real and recurring.

## Adding a fragment

One file per PR (or per distinct change, if a PR carries more than one worth recording):

```
changelog.d/<slug>.md
```

`<slug>` is a short kebab-case descriptor — usually the branch or feature name — chosen so
it will not collide with another open PR (`spa-guard-cascade`, `import-map-order`,
`changelog-fragments`). There is **no** type or section suffix in the filename; the section
lives in the file body, so one fragment can populate several sections.

## Fragment content

The body is one or more `### <Section>` headings, each followed by Markdown bullet lines.
The assembler aggregates the bullets **per section, across all fragments**, so what you
write under `### Added` here lands under the single `### Added` of the release section.

```markdown
### Added

- `spa.head` hook: a `.spa.tsx` may now contribute `<head>` content per route.

### Fixed

- The import map is emitted before any `modulepreload`, since the first module script
  closes the window in which a map may be declared.
```

Rules the assembler enforces, each a hard failure:

- Every non-blank line must sit under a `### <Section>` heading — content before the first
  heading is rejected rather than silently dropped.
- The section name must be one of the recognized ones below. A typo (`### Fixes`) fails the
  build instead of quietly inventing a section.
- A fragment with no heading, or with headings but no bullets, is rejected.

Blank lines *inside* a section are preserved, so a bullet may carry an indented follow-up
paragraph. Blank lines at the start and end of a section are trimmed, so bullets from
different fragments aggregate into one tight list.

### Recognized sections

The assembler emits these in this order and omits any that are empty. The first six are
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/)'s set, which the top of
`CHANGELOG.md` commits this project to.

| # | section                | use for                                                            |
| - | ---------------------- | ------------------------------------------------------------------ |
| 1 | `### Added`            | new features and capabilities                                       |
| 2 | `### Changed`          | changes to existing behaviour (call out the migration in the bullet)|
| 3 | `### Deprecated`       | soon-to-be-removed features                                         |
| 4 | `### Removed`          | removed features                                                    |
| 5 | `### Fixed`            | bug fixes                                                           |
| 6 | `### Security`         | vulnerability fixes and security-relevant behaviour changes          |
| 7 | `### Known limitations`| the standing "what this release still cannot do" list               |
| 8 | `### Internal`         | contributor-facing changes with no user-visible effect              |

Two notes on the last two, which are not Keep a Changelog's:

- **`Known limitations`** is a *restatement*, not a delta — `0.1.0` carries one (no Windows,
  FreeBSD 15+ for live reload, CSP header is the host's job, pre-1.0 API churn). At release,
  carry forward the entries that are still true and add any new one. It is written as
  fragments like everything else so a PR that introduces or lifts a limitation records it at
  the time, not from memory months later.
- **`Internal`** renders last and is for changes only a contributor notices: build/CI, test
  infrastructure, refactors, dev tooling, the release process itself. Sections 1–6 are for
  what a Zigapagos *user* experiences.

Decision rule:

> **Would someone building a site with Zigapagos notice?** → a user-facing section.
> **Only a contributor notices?** → `Internal`.
> **Nobody needs it recorded?** → no fragment at all; git history is enough.

## How this coexists with `## [Unreleased]`

`CHANGELOG.md` keeps its `## [Unreleased]` heading, but its body is a **pointer to this
directory, not a place to write**. Putting bullets there would reintroduce exactly the
shared-lines conflict fragments exist to avoid.

So: to see what is pending for the next release, read `changelog.d/`. The assembler inserts
the new version section *below* `## [Unreleased]` and leaves that section's text alone —
because it is a static pointer, there is nothing to reset after a release.

## At release

The release PR runs:

```sh
bash scripts/assemble-changelog.sh [<version> [<date>]] [--dry-run]
```

`<version>` defaults to `build.zig.zon`'s `.version` (the single source of truth) and
`<date>` to today in UTC. `--dry-run` prints the section it would insert and the fragments
it would remove, and writes nothing. The script:

1. reads every `changelog.d/*.md` (`README.md` is not a fragment) and splits each on its
   `### <Section>` headings,
2. aggregates the bullets per section, in the canonical order above, under a new
   `## [<version>] - <date>` heading,
3. inserts that block into `CHANGELOG.md` above the most recent released version,
4. updates the reference-style links at the foot of the file — the new version gets a
   compare link, and `[Unreleased]` is re-pointed at `v<version>...HEAD`, and
5. `git rm`s the consumed fragments.

The heading format is **load-bearing, not cosmetic**: `scripts/extract-release-notes.sh`
finds a section by matching `## [<version>]` at the start of a line and slices through to
the next `## `, and the `v*` release workflow uses the result as the GitHub release body. A
malformed heading does not fail the build — it silently produces empty or over-long release
notes. Read the assembled section before merging the release PR.

(What exactly that extractor puts in the body — whether the heading line itself survives,
where it stops trimming — is its business, not the assembler's. What is fixed between them
is the heading: `## [x.y.z] - YYYY-MM-DD`, bare semver, ASCII hyphen, single spaces.)

Do not run the assembler in a feature PR. Add your fragment; that is the whole job.
