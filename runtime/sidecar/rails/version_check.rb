# Fails loudly if the pinned Ruby cannot provide Prism from stdlib.
# `static_ast` mode is gem-free by design, so a missing stdlib Prism is a
# toolchain defect, not something to degrade around.
require "prism"
require "json"

min = Gem::Version.new("3.3.0")
if Gem::Version.new(RUBY_VERSION) < min
  warn "rails sidecar needs Ruby >= #{min} for stdlib Prism, got #{RUBY_VERSION}"
  exit 1
end
puts JSON.generate({ ruby: RUBY_VERSION, prism: Prism::VERSION })
