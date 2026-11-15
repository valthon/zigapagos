### Fixed

- Migration recognizes Hugo front-matter openers with trailing blanks and Hexo fence-less scalar YAML metadata, preserving titles, dates, and unpublished posts, including the YAML 1.2 spellings `False`/`FALSE` and `True`/`TRUE` for `draft` and `published`. Eleventy language-tagged front matter is preserved for review and forced to draft instead of leaking code and private content into published pages (#251, #252 part 1, #258).
