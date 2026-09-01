#
# Default-locale translation lookup for the templates op. Reads YAML with
# Psych (a default gem shipped with every supported Ruby; no bundler) and
# NEVER evaluates a locale file -- `YAML.safe_load` only, with alias
# expansion left OFF (`aliases: false`). The sidecar analyzes untrusted
# third-party Rails apps, so a locale file is adversarial input: an ALIAS
# REFERENCE (`*ref`) lets a small file expand into a huge in-memory
# structure ("billion laughs"), and refusing alias references closes that
# hole regardless of what classes are permitted. An anchor DEFINITION
# (`&ref`) with nothing referencing it is not itself the hole -- it loads
# like any other mapping/sequence -- so only `*ref` is refused, not `&ref`.
# `permitted_classes: [Symbol, Date, Time]` allows three plain-scalar tags:
# Symbol because Rails' own shipped locale file,
# `activesupport/lib/active_support/locale/en.yml`, uses a Symbol array
# (`date.order: [:year, :month, :day]`), and apps copy that idiom into
# their own locale files, so refusing Symbol would reject files that are
# completely ordinary Rails; Date and Time because Psych's core schema
# resolves an UNTAGGED scalar like `since: 2024-01-01` or
# `at: 2024-01-01 12:00:00` to one of them with no explicit type tag at
# all, and Rails itself loads such a file without complaint
# (`YAML.unsafe_load_file`), so refusing them would reject files Rails
# accepts fine. None of the three is a code-execution or size-expansion
# vector under `safe_load` -- they are plain scalars, not an instantiation
# vector -- so permitting them does not reopen the hole `aliases: false`
# closes; a non-String leaf (Symbol, Date, Time, or anything else) is
# simply ignored by `Table#lookup`, which only ever returns a String. Any
# other YAML type tag is still refused. A locale file that relies on an
# alias reference or an unpermitted type tag degrades the same way a
# syntactically broken one does -- Psych raises, `load` records it in
# `Table#errors` instead of merging it, and the run continues. Only the
# default locale converts in this stage; every other locale is out of
# scope by the spec and never loaded.
require "yaml"

module RailsI18n
  class Table
    attr_reader :locale, :errors

    def initialize(locale)
      @locale = locale
      @data = {}
      @errors = []
    end

    def merge!(hash)
      deep_merge!(@data, hash)
    end

    def lookup(key)
      node = @data
      key.split(".").each do |part|
        return nil unless node.is_a?(Hash) && node.key?(part)
        node = node[part]
      end
      node.is_a?(String) ? node : nil
    end

    private

    def deep_merge!(into, from)
      from.each do |k, v|
        # The i18n gem loads locale files with `symbolize_names: true`, so
        # `:k:` and `k:` name the same key from Rails' perspective. `lookup`
        # only ever walks String parts, so a Symbol key surviving into
        # `@data` un-normalized makes an otherwise Rails-resolvable key
        # report as missing -- normalize here, at every recursion depth,
        # not just the top-level key already handled by `load`'s
        # `doc[table.locale.to_sym]` fallback.
        key = k.is_a?(Symbol) ? k.to_s : k
        if v.is_a?(Hash) && into[key].is_a?(Hash)
          deep_merge!(into[key], v)
        else
          into[key] = v
        end
      end
    end
  end

  DEFAULT_LOCALE_RE = /config\.i18n\.default_locale\s*=\s*(?::["']?([\w-]+)["']?|["']([\w-]+)["'])/

  def self.default_locale(root)
    src = File.read(File.join(root, "config/application.rb"))
    # A commented-out assignment is documentation, not configuration. Match
    # the first live assignment line instead of the first byte pattern in the
    # whole source file.
    m = src.each_line.lazy.reject { |line| line.lstrip.start_with?("#") }
           .map { |line| DEFAULT_LOCALE_RE.match(line) }.find(&:itself)
    m ? (m[1] || m[2]) : "en"
  rescue SystemCallError, IOError
    "en"
  end

  def self.load(root)
    root = File.expand_path(root)
    table = Table.new(default_locale(root))
    locale_docs = []
    found_locale = false
    Dir.glob(File.join(root, "config/locales/**/*.{yml,yaml}")).sort.each do |file|
      rel = file.delete_prefix("#{root}/")
      begin
        doc = YAML.safe_load(File.read(file), permitted_classes: [Symbol, Date, Time], aliases: false)
      rescue Psych::BadAlias => e
        table.errors << {
          path: rel,
          detail: "#{e.class}: YAML aliases (`*ref`) are not accepted in locale files; inline the referenced block",
        }
        next
      rescue Psych::DisallowedClass => e
        table.errors << {
          path: rel,
          detail: "#{e.class}: YAML value of a type not permitted in locale files (#{e.message})",
        }
        next
      rescue StandardError => e
        table.errors << { path: rel, detail: "#{e.class}: #{e.message.lines.first.to_s.strip}" }
        next
      end
      unless doc.is_a?(Hash)
        table.errors << { path: rel, detail: "locale document must be a mapping" }
        next
      end
      locale_docs << rel
      slice = doc[table.locale] || doc[table.locale.to_sym]
      if slice.is_a?(Hash)
        found_locale = true
        table.merge!(slice)
      end
    end
    if !locale_docs.empty? && !found_locale
      table.errors << {
        path: locale_docs.first,
        detail: "default locale #{table.locale.inspect} was not found in any locale document",
      }
    end
    table
  end

  # Rails' scope_key_by_partial: `.key` inside app/views/posts/index.html.erb
  # is `posts.index.key`; a partial's leading underscore is dropped.
  def self.expand_lazy(key, template_rel_path)
    return key unless key.start_with?(".")
    rel = template_rel_path.delete_prefix("app/views/")
    base = rel.sub(/\..*\z/, "") # strip every extension: index.html.erb -> index
    parts = base.split("/")
    parts[-1] = parts[-1].delete_prefix("_")
    "#{parts.join(".")}#{key}"
  end
end
