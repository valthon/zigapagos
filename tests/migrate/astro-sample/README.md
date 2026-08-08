# `zigapagos migrate` sample Astro project

A tiny fixture marketing site used to exercise `zigapagos migrate`'s island
detection and Props inference. It deliberately contains the cases that a real
Astro site hits and that earlier versions of the tool got wrong:

- **`Counter.jsx`** and **`ContactForm.tsx`** are used **with** a `client:*`
  directive → real islands.
- **`Footer.astro`** is a static component used **without** any `client:*` →
  must map to a SuperHTML **partial**, not an island.
- **`Recaptcha.tsx`** is a transitive child of `ContactForm` that is never used
  with a `client:*` directive → **not** an island (port only if its island needs
  it). Its `onChange` callback must never be emitted as an island prop.
- **`ContactForm`**'s props include a scalar, an **object** (`ThemeConfig` →
  struct stub) and a **callback** (`onSuccess` → skipped with a note).
- **`src/pages/blog/[page].astro`** calls `paginate()` from `getStaticPaths` →
  a **worklist conversion instruction** (delete the route file, add
  `.pagination` to `content/blog/index.smd`), not an island or a partial.

Run it:

```
zigapagos migrate tests/migrate/astro-sample --scaffold /tmp/out
```

Expected: 2 islands (`Counter`, `ContactForm`), 1 partial (`Footer`), and
`Recaptcha` listed only as a non-island transitive child.
