require "tmpdir"
require "fileutils"
require_relative "../i18n"

$failures = 0
def check(label, cond)
  return if cond
  warn "FAIL #{label}"; $failures += 1
end

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales/nested"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :fr\n  end\nend\n")
  File.write(File.join(dir, "config/locales/fr.yml"), "fr:\n  posts:\n    index:\n      heading: \"Articles\"\n  nav:\n    home: \"Accueil\"\n")
  File.write(File.join(dir, "config/locales/en.yml"), "en:\n  nav:\n    home: \"Home\"\n")
  File.write(File.join(dir, "config/locales/nested/extra.yml"), "fr:\n  extra:\n    deep: \"Profond\"\n    list: [1, 2]\n")
  File.write(File.join(dir, "config/locales/broken.yml"), "fr: [unclosed\n")

  t = RailsI18n.load(dir)
  check("locale from application.rb", t.locale == "fr")
  check("nested lookup", t.lookup("posts.index.heading") == "Articles")
  check("only the default locale is merged", t.lookup("nav.home") == "Accueil")
  check("nested directory files load", t.lookup("extra.deep") == "Profond")
  check("non-string leaf is nil", t.lookup("extra.list").nil?)
  check("missing key is nil", t.lookup("nope.nope").nil?)
  check("malformed file recorded, not fatal", t.errors.any? { |e| e[:path] == "config/locales/broken.yml" })
end

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :\"pt-BR\"\n  end\nend\n")
  File.write(File.join(dir, "config/locales/pt-BR.yml"), "pt-BR:\n  greeting: \"Olá\"\n")

  t = RailsI18n.load(dir)
  check("hyphenated locale pt-BR from application.rb", t.locale == "pt-BR")
  check("hyphenated locale lookup", t.lookup("greeting") == "Olá")
end

Dir.mktmpdir do |dir|
  t = RailsI18n.load(dir)
  check("no config/locales: empty table, locale en", t.locale == "en" && t.lookup("x").nil? && t.errors.empty?)
end

# The sidecar analyzes untrusted third-party Rails apps, so a locale file
# is adversarial input. YAML aliases are disabled (`aliases: false`),
# closing the "billion laughs" hole regardless of what classes are
# permitted. Symbol IS permitted (`permitted_classes: [Symbol, Date, Time]`)
# because Rails' own shipped locale file uses a Symbol array
# (`date.order: [:year, :month, :day]`) and apps copy that idiom -- so a
# locale file that merely uses Symbol (a top-level key, or a value) must
# load like any other well-formed file, while a file that relies on
# aliases must still degrade the same way `broken.yml` does above:
# recorded in `table.errors`, never merged, and the run keeps going -- it
# must NOT raise out of `RailsI18n.load` and it must NOT expand a small
# file into a huge one ("billion laughs").
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :fr\n  end\nend\n")
  File.write(File.join(dir, "config/locales/fr.yml"), "fr:\n  greeting: \"Bonjour\"\n")
  File.write(File.join(dir, "config/locales/alias.yml"), "fr: &fr\n  shared: \"Partage\"\nen:\n  <<: *fr\n")
  # A Symbol TOP-LEVEL KEY (`:fr:` rather than `fr:`) -- some locale files
  # are authored this way. It doesn't match the String locale name
  # directly, so `load` falls back to `doc[table.locale.to_sym]`.
  File.write(File.join(dir, "config/locales/symbols.yml"), ":fr:\n  via_symbol: \"Salut\"\n")
  # A Symbol VALUE nested under an ordinary String top-level key -- the
  # `date.order: [:year, :month, :day]` idiom straight out of Rails'
  # `activesupport/lib/active_support/locale/en.yml`. The `line` string
  # key in the same file must still resolve, and the file must not be
  # recorded as an error at all.
  File.write(File.join(dir, "config/locales/symbol_value.yml"), "fr:\n  date:\n    order:\n    - :year\n    - :month\n    - :day\n  line:\n    label: \"Ligne\"\n")
  File.write(
    File.join(dir, "config/locales/bomb.yml"),
    "lol1: &lol1 [\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\"]\n" \
    "lol2: &lol2 [*lol1,*lol1,*lol1,*lol1,*lol1,*lol1,*lol1,*lol1,*lol1]\n" \
    "lol3: &lol3 [*lol2,*lol2,*lol2,*lol2,*lol2,*lol2,*lol2,*lol2,*lol2]\n" \
    "fr:\n  canary: \"should not merge\"\n  bomb: *lol3\n"
  )

  t = RailsI18n.load(dir)
  check("a normal locale file still loads alongside rejected ones", t.lookup("greeting") == "Bonjour")
  check("an alias-using file is not merged", t.lookup("shared").nil?)
  check(
    "an alias-using file is recorded as an error naming aliases, with a remedy the operator can apply",
    t.errors.any? do |e|
      e[:path] == "config/locales/alias.yml" &&
        e[:detail] == "Psych::AliasesNotEnabled: YAML aliases (`*ref`) are not accepted in locale files; inline the referenced block"
    end
  )
  check("a Symbol top-level-key file merges via the to_sym fallback", t.lookup("via_symbol") == "Salut")
  check(
    "a Symbol top-level-key file is not recorded as an error",
    t.errors.none? { |e| e[:path] == "config/locales/symbols.yml" }
  )
  check("the string key beside a Symbol value resolves", t.lookup("line.label") == "Ligne")
  check(
    "a file using a Symbol value is not recorded as an error",
    t.errors.none? { |e| e[:path] == "config/locales/symbol_value.yml" }
  )
  check("a billion-laughs-shaped file is not merged", t.lookup("canary").nil?)
  check(
    "a billion-laughs-shaped file is recorded as an error naming aliases, without expanding",
    t.errors.any? { |e| e[:path] == "config/locales/bomb.yml" && e[:detail].include?("Alias") }
  )
end

# A NESTED Symbol key (as opposed to the top-level Symbol key covered
# above) must resolve the same way a String key does: the i18n gem loads
# locale files with `symbolize_names: true`, so `:nested_sym:` and
# `nested_sym:` name the same key from Rails' perspective. `Table#lookup`
# walks String parts, so a Symbol key that survives un-normalized into
# `@data` makes an otherwise Rails-resolvable key report as missing.
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :en\n  end\nend\n")
  File.write(File.join(dir, "config/locales/en.yml"), "en:\n  greeting: hi\n  :nested_sym: via-symbol-key\n")

  t = RailsI18n.load(dir)
  check("a nested Symbol key resolves the same as a String key", t.lookup("nested_sym") == "via-symbol-key")
  check("a file with only a nested Symbol key is not recorded as an error", t.errors.empty?)
end

# An anchor DEFINITION (`&fr`) with nothing ever referencing it is not the
# "billion laughs" hole -- nothing expands until an alias (`*fr`) reads it
# back -- so `aliases: false` (which refuses the ALIAS reference, per
# `Psych::BadAlias`'s parent `AliasesNotEnabled`) must not also reject the
# anchor by itself. This is a probe of documented behavior, not a
# regression pin: `YAML.safe_load(..., aliases: false)` already lets an
# unreferenced anchor through on both sides of this round's fix; what
# changed this round is only the error WORDING (see the alias check above),
# which used to overclaim that "aliases/anchors" together were refused.
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :fr\n  end\nend\n")
  File.write(File.join(dir, "config/locales/anchor_only.yml"), "fr: &fr\n  a: \"b\"\n")

  t = RailsI18n.load(dir)
  check("an anchor definition with no alias reference loads normally", t.lookup("a") == "b")
  check("an anchor-only file is not recorded as an error", t.errors.none? { |e| e[:path] == "config/locales/anchor_only.yml" })
end

# Psych's core schema resolves an UNTAGGED `since: 2024-01-01` to Date (and
# `2024-01-01 12:00:00` to Time) with no explicit type tag at all -- Rails
# itself loads such a locale file fine (`YAML.unsafe_load_file`). Before
# this round `permitted_classes` was `[Symbol]` only, so a completely
# ordinary Rails locale file that merely mentions a bare date was refused
# with `Psych::DisallowedClass`, and the greeting alongside it in the SAME
# file never resolved either (the whole document fails to parse before
# anything can be merged). Neither Date nor Time is a code-execution or
# size-expansion vector under `safe_load` (they are plain scalars, not an
# instantiation vector), and `Table#lookup` already ignores any non-String
# leaf -- so permitting them costs nothing and fixes the false refusal.
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :fr\n  end\nend\n")
  File.write(File.join(dir, "config/locales/dates.yml"), "fr:\n  greeting: \"hi\"\n  since: 2024-01-01\n  at: 2024-01-01 12:00:00\n")

  t = RailsI18n.load(dir)
  check("a file with an untagged Date/Time scalar still merges its String siblings", t.lookup("greeting") == "hi")
  check("an untagged Date scalar leaf resolves to nil (non-String, ignored by lookup)", t.lookup("since").nil?)
  check("an untagged Time scalar leaf resolves to nil (non-String, ignored by lookup)", t.lookup("at").nil?)
  check("a file using only permitted scalar types is not recorded as an error", t.errors.empty?)
end

# `rel = file.delete_prefix("#{root}/")` used to fail silently when `root`
# itself already ends with "/": `File.join` collapses the doubled slash
# (`root//config/...` -> `root/config/...`), so the literal `"#{root}/"`
# prefix (with the doubled slash) never matches the glob result, and
# `delete_prefix` is a no-op -- the ABSOLUTE path leaks into `errors[].path`
# instead of the root-relative one. `RailsI18n.load` now normalizes with
# `File.expand_path` up front, which also strips a trailing slash, so this
# can no longer happen regardless of how the caller spelled `root`.
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/locales/broken.yml"), "fr: [unclosed\n")

  t = RailsI18n.load("#{dir}/")
  check("a trailing-slash root still reports a root-relative error path", t.errors[0] && t.errors[0][:path] == "config/locales/broken.yml")
end

check("lazy key in a view", RailsI18n.expand_lazy(".heading", "app/views/posts/index.html.erb") == "posts.index.heading")
check("lazy key in a partial drops the underscore", RailsI18n.expand_lazy(".title", "app/views/posts/_post.html.erb") == "posts.post.title")
check("lazy key in a nested layout", RailsI18n.expand_lazy(".brand", "app/views/layouts/admin/base.html.erb") == "layouts.admin.base.brand")
check("absolute key untouched", RailsI18n.expand_lazy("nav.home", "app/views/x.html.erb") == "nav.home")

abort "#{$failures} i18n failure(s)" if $failures > 0
puts "PASS: i18n_test.rb"
