### Changed

- `zigapagos init` now scaffolds only the frontmatter a page needs. `.author`
  and `.draft` are gone from every template and `.date` remains only on the blog
  posts and devlog years whose listing layouts render one — `.title` and
  `.layout` are the only required fields, and the scaffold no longer models the
  optional ones as obligatory. The sample homepage and the quick start now say
  which fields have defaults.
