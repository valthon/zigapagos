require_relative "../templates"
require_relative "../i18n"

$failures = 0
I18N = RailsI18n::Table.new("en")
I18N.merge!({ "posts" => { "index" => { "heading" => "Posts" } }, "nav" => { "home" => "Home" } })

def kinds(src, path: "app/views/posts/index.html.erb")
  res = RailsTemplates.analyze(src, path: path, i18n: I18N)
  raise "unexpected error #{res.inspect}" if res[:error]
  res[:nodes].select { |n| n[:t] == "code" }
end

def check(label, src, expected_kinds, path: "app/views/posts/index.html.erb")
  got = kinds(src, path: path).map { |n| n[:kind] }
  return if got == expected_kinds
  warn "FAIL #{label}\n  expected: #{expected_kinds.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

def check_node(label, src, index, expected_subset, path: "app/views/posts/index.html.erb")
  node = kinds(src, path: path)[index]
  ok = node && expected_subset.all? { |k, v| node[k] == v }
  return if ok
  warn "FAIL #{label}\n  expected ⊇ #{expected_subset.inspect}\n  actual:   #{node.inspect}"
  $failures += 1
end

check "yield and named yield", "<%= yield %><%= yield :head %><%= content_for?(:side) %>", %w[yield yield_named yield_named]
check_node "named yield carries its name", "<%= yield :head %>", 0, { name: "head" }

check "content_for block and provide", "<% content_for :title do %>x<% end %><% provide(:title, \"T\") %>",
      %w[content_for block_end content_for]
check_node "provide carries literal value", "<% provide(:title, \"T\") %>", 0, { name: "title", value: "T" }

check "partials: literal, literal locals, collection, ivar",
      "<%= render \"nav\" %><%= render partial: \"post\", locals: { a: 1 } %><%= render partial: \"post\", collection: @posts %><%= render @post %>",
      %w[render_partial render_partial_locals render_dynamic render_dynamic]
check_node "literal partial target", "<%= render partial: \"shared/nav\" %>", 0, { name: "shared/nav" }
check_node "literal locals are attrs", "<%= render partial: \"post\", locals: { a: 1, b: \"x\" } %>", 0, { attrs: [["a", "1"], ["b", "x"]] }

check "route helpers", "<%= posts_path %><%= post_path(1) %><%= post_path(@post) %><%= root_url %>",
      %w[route_helper route_helper route_helper_dynamic route_helper]
check_node "route helper name is the stem", "<%= post_path(1) %>", 0, { name: "post", args: ["1"] }

check "link_to literal vs dynamic",
      "<%= link_to \"Home\", root_path %><%= link_to \"P\", post_path(@p) %><%= link_to @p.title, root_path %>",
      %w[link_to route_helper_dynamic route_helper_dynamic]
check_node "link_to carries text and target", "<%= link_to \"Home\", root_path, class: \"x\" %>", 0,
           { name: "root", args: ["Home"], attrs: [["class", "x"]] }

check "assets, importmap, csrf",
      "<%= image_tag \"logo.png\" %><%= stylesheet_link_tag \"application\" %><%= javascript_importmap_tags %><%= csrf_meta_tags %><%= csp_meta_tag %>",
      %w[asset asset importmap csrf csrf]
check_node "asset name", "<%= image_tag \"logo.png\", alt: \"L\" %>", 0, { name: "image_tag", args: ["logo.png"], attrs: [["alt", "L"]] }

check "i18n resolves absolute and lazy keys", "<%= t(\"nav.home\") %><%= t(\".heading\") %><%= t(\".nope\") %>", %w[i18n i18n i18n]
check_node "resolved value", "<%= t(\".heading\") %>", 0, { name: "posts.index.heading", value: "Posts" }
check_node "missing key", "<%= t(\".nope\") %>", 0, { name: "posts.index.nope", missing: true }

check "literals", "<%= \"a\" %><%= 1 %><%= nil %>", %w[literal literal literal]

check "form with fields and errors",
      "<%= form_with(model: @post, url: \"/posts\") do |f| %><%= f.label :title %><%= f.text_field :title %><%= f.submit \"Go\" %><% end %><% if @post.errors.any? %><%= @post.errors.full_messages %><% end %>",
      %w[form form_field form_field form_field block_end errors errors block_end]
check_node "form attrs and model", "<%= form_with(model: @post, url: \"/posts\") do |f| %><% end %>", 0,
           { attrs: [["url", "/posts"]], name: "post", dynamic: true }
check_node "form field carries builder method and field", "<%= form_with(url: \"/x\") do |f| %><%= f.email_field :email %><% end %>", 1,
           { name: "email_field", args: ["email"] }

check "request state and ivars",
      "<%= current_user.name %><% if signed_in? %><% end %><%= session[:x] %><%= @posts.count %><%= Current.account %>",
      %w[request_state request_state block_end request_state ivar request_state]
check_node "request_state names the marker", "<%= current_user.name %>", 0, { name: "current_user" }

check "locals", "<%= post.title %><%= post %>", %w[local local]

check "control flow", "<% if true %>a<% else %>b<% end %><% 3.times do %><% end %>",
      %w[control block_else block_end control block_end]
check "control with request state or ivar is that, not control",
      "<% @posts.each do |p| %><%= p.title %><% end %>", %w[ivar local block_end]

check "turbo and components",
      "<%= turbo_frame_tag \"x\" do %><% end %><%= turbo_stream_from @post %><%= react_component(\"Hello\", { name: \"n\" }) %><%= react_component(\"Hello\", @props) %>",
      %w[turbo_frame block_end turbo_stream component_root component_root]
check_node "component props literal", "<%= react_component(\"Hello\", { name: \"n\" }) %>", 0, { name: "Hello", attrs: [["name", "n"]] }
check_node "component props dynamic", "<%= react_component(\"Hello\", @props) %>", 0, { name: "Hello", dynamic: true }

check "raw", "<%== x %><%= raw(y) %><%= z.html_safe %>", %w[raw raw raw]

check "unknown helper", "<%= number_to_currency(3) %>", %w[unknown]
check_node "unknown names the method", "<%= number_to_currency(3) %>", 0, { name: "number_to_currency" }

# A template whose fragments do not assemble into a valid program is a parse
# error at the offending line -- never a partial node list.
res = RailsTemplates.analyze("<p>\n<% if x %>\n</p>\n", path: "app/views/posts/index.html.erb", i18n: I18N)
unless res[:error] && res[:line].is_a?(Integer)
  warn "FAIL parse error reporting: #{res.inspect}"; $failures += 1
end

# Text nodes interleave in order with true line numbers.
res = RailsTemplates.analyze("<h1>\n  <%= yield %>\n</h1>\n", path: "app/views/layouts/application.html.erb", i18n: I18N)
texts = res[:nodes].select { |n| n[:t] == "text" }.map { |n| [n[:text], n[:line]] }
# (`col` is 7, not the tag's own 3: ruling R17 reports where the FRAGMENT
# starts -- `<%= ` is four bytes -- so that two fragments inside one tag can
# never share a column. See (g) below.)
unless texts == [["<h1>\n  ", 1], ["\n</h1>\n", 2]] && res[:nodes][1][:kind] == "yield" && res[:nodes][1][:line] == 2 && res[:nodes][1][:col] == 7
  warn "FAIL text interleave: #{res[:nodes].inspect}"; $failures += 1
end


# ---------------------------------------------------------------------------
# Regressions for the four deviations from the task brief's reference code and
# for the two silent-loss defects found in review. Each pins a property that
# nothing above pins, and each was verified to fail against the code as it
# stood before its fix.
# ---------------------------------------------------------------------------

def check_positions(label, src, expected, path: "app/views/posts/index.html.erb")
  got = kinds(src, path: path).map { |n| [n[:kind], n[:line], n[:col]] }
  return if got == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

# (a) Line/col fidelity across a multi-line layout. erb.rb's trim rules swallow
# the newline that ends a code-only tag's line, and the compiled program is not
# line-aligned with the template at all, so EVERY position here is a mapped one.
# The columns are the FRAGMENTS' true byte offsets in the source, counted
# 1-based: `if` at 4 (past `<% `), `@user` at 13, `Time` at 34, `yield` at 11.
# Ruling R17 moved these off the enclosing TAG's column (1, 9, 30, 7) -- a tag
# holding two fragments cannot give both of them its own column, and the
# resulting duplicate `L<line>C0` fallbacks collided as finding ids. A
# `block_end` whose `end` has no token of its own still reports 0; it is a
# structural marker, not a fragment, and no finding is derived from one.
LAYOUT = "<!DOCTYPE html>\n<html>\n<body>\n<% if @user %>\n  <p>Hi <%= @user.name %> at <%= Time.now %></p>\n<% end %>\n<main><%= yield %></main>\n</body>\n</html>\n"
check_positions "every code node reports its true source line and column", LAYOUT,
                [["ivar", 4, 4], ["ivar", 5, 13], ["unknown", 5, 34], ["block_end", 6, 1], ["yield", 7, 11]],
                path: "app/views/layouts/application.html.erb"

# (b) A construct written entirely inside ONE tag has an `end` with no token of
# its own, so `block_end` must leave the queue alone: the FOLLOWING tag keeps
# its own column and code. (A one-tag block still leaks its inner statements
# into the stream as spurious nodes -- a known, separately-tracked limit -- so
# this pins the token queue on a one-tag block with an empty body, where the
# leak cannot mask the property under test.)
check_positions "block_end consumes no token when the `end` had none",
                "<% while x do end %><%= 2 %>",
                [["control", 1, 4], ["block_end", 1, 0], ["literal", 1, 25]]
check_node "the fragment after it keeps its own code", "<% while x do end %><%= 2 %>", 2, { code: "2", value: "2" }
check_node "a self-contained if reports the whole tag as its code", "<% if x then y end %>", 0,
           { kind: "control", code: "if x then y end" }

# (c) Every code node carries `output:`, statements included -- the node schema
# says Boolean, and a missing key is not one.
check_node "a statement node is output: false", "<% if true %><% end %>", 0, { kind: "control", output: false }
check_node "a block_end is output: false", "<% if true %><% end %>", 1, { kind: "block_end", output: false }
check_node "an output node is output: true", "<%= 1 %>", 0, { output: true }

# (d) `case` branches are block boundaries like `else`/`elsif`, and each
# `<% when %>` fragment is consumed so later nodes keep their own positions.
check "case emits a block_else per branch", "<% case @s %><% when 1 %>a<% else %>b<% end %><%= 3 %>",
      %w[ivar block_else block_else block_end literal]
check_node "the fragment after a case keeps its own code", "<% case @s %><% when 1 %>a<% else %>b<% end %><%= 3 %>", 4, { code: "3" }

# (e) Ruby binds an un-parenthesised brace block to the INNERMOST command
# argument (`root_path` here, not `link_to`). Missing it deleted the tag's body
# from the stream and left `<% } %>` to land on the following fragment.
res = RailsTemplates.analyze("<%= link_to root_path { %>x<% } %><%= 5 %>", path: "app/views/posts/index.html.erb", i18n: I18N)
brace = res[:nodes]
unless !res[:error] && brace.any? { |n| n[:t] == "text" && n[:text] == "x" } &&
       brace.map { |n| n[:kind] }.compact == %w[route_helper_dynamic block_end literal] &&
       brace.last[:col] == 39 && brace.last[:code] == "5"
  warn "FAIL brace block body and following fragment: #{res.inspect}"; $failures += 1
end

# (f) A Ruby comment inside a tag must not swallow the rest of the compiled
# line. Rails renders both of these; neither may lose a node or invent an error.
check "a comment tag does not truncate the fragment after it", "<% # c %><%= 1 %>", %w[literal]
res = RailsTemplates.analyze("<% # c %>\n<p>x</p>\n", path: "app/views/posts/index.html.erb", i18n: I18N)
unless res[:error].nil? && res[:nodes].map { |n| n[:text] } == ["<p>x</p>\n"]
  warn "FAIL comment tag with a following line: #{res.inspect}"; $failures += 1
end

# (g) Ruling R17: `emit` fell back to `col: 0` whenever the line's token
# queue was empty, so every statement after the FIRST in a multi-statement tag
# reported column 0 -- two of them on one line produced two findings with the
# identical id `<code>.<path>.L1C0`, which is precisely the uniqueness
# `findings.zig`'s `lessThan` doc rests its total order on. A column is now
# mapped back from Prism's own position, so each statement reports where it
# really is.
check_positions "each statement in a multi-statement tag reports its own source column",
                "<% number_to_currency(1); pluralize(2); truncate(3) %>",
                [["unknown", 1, 4], ["unknown", 1, 27], ["unknown", 1, 41]]

# A tag spanning several lines: its continuation lines are verbatim source, so
# their statements' columns are their own indentation, not the opening tag's.
check_positions "a multi-line tag maps each line's statements to that line's columns",
                "<%\n  foo\n  bar\n%>",
                [["local", 2, 3], ["local", 3, 3]]

# An output tag's generated line opens with a six-byte `_out((`/`_outb `
# prefix that has no counterpart in the template. Subtracting it is what keeps
# an output tag's column honest -- without it every `<%= %>` reports six
# columns too far right.
check_positions "an output tag's column skips the generated call prefix",
                "<h1><%= t(\".heading\") %></h1>", [["i18n", 1, 9]]
check_node "a block-form output tag skips its prefix too",
           "<%= form_with(url: \"/x\") do |f| %><% end %>", 0, { kind: "form", col: 5 }

# ...and if that six ever stops matching what `fragment_source` actually
# writes, every output tag's column shifts silently. Pin the two together.
[["=", " x "], ["=", " form_with(url: 1) do |f| "], ["==", " y "], ["", " z "], ["-", " w "]].each do |ind, code|
  tok = { type: :code, indicator: ind, code: code, line: 1, col: 1 }
  gen = RailsTemplates.fragment_source(tok)
  n = RailsTemplates.fragment_prefix_length(tok)
  next if gen[n, code.length] == code
  warn "FAIL fragment_prefix_length disagrees with fragment_source for #{ind.inspect}: #{gen.inspect}, prefix #{n}"
  $failures += 1
end

# ---------------------------------------------------------------------------
# #167 Stage 3 (Task 3 round 3, N-2): a nested `data:` hash reaches the Zig
# side as the attributes Rails would have RENDERED. Before this, the hash was
# reported as one `data` key holding the `{...}` sentinel, so the Rails 7 /
# Turbo spelling of a destructive link -- `data: { turbo_method: :delete }` --
# raised no finding (`findings.mutationVerb` reads `data-turbo-method`) and
# converted to a GET link carrying `data="{...}"`.
# ---------------------------------------------------------------------------

check_node "a nested data: hash flattens to dasherised data-* attrs, in source order",
           "<%= link_to \"Sign out\", logout_path, data: { turbo_method: :delete, turbo_confirm: \"Sign out?\" } %>", 0,
           { kind: "link_to", name: "logout", args: ["Sign out"],
             attrs: [["data-turbo-method", "delete"], ["data-turbo-confirm", "Sign out?"]] }
check_node "a literal-path link flattens the same way",
           "<%= link_to \"Sign out\", \"/logout\", data: { turbo_method: :delete } %>", 0,
           { kind: "link_to", name: nil, args: ["Sign out", "/logout"], attrs: [["data-turbo-method", "delete"]] }
# Rails' `tag_options`: a String/Symbol value as is, any other scalar
# JSON-encoded, a nil value skipped, a string key dasherised like a symbol one.
check_node "booleans and numbers render as Rails renders them; a nil pair is omitted",
           "<%= link_to \"x\", root_path, data: { turbo: false, \"item_count\" => 3, gone: nil, \"already-dashed\" => 1.5 } %>", 0,
           { kind: "link_to", attrs: [["data-turbo", "false"], ["data-item-count", "3"], ["data-already-dashed", "1.5"]] }
check_node "the flattened pairs sit where data: sat among the other options",
           "<%= link_to \"x\", root_path, class: \"a\", data: { turbo_method: :delete }, id: \"b\" %>", 0,
           { attrs: [["class", "a"], ["data-turbo-method", "delete"], ["id", "b"]] }
check_node "aria: is the other prefix Rails flattens",
           "<%= link_to \"x\", root_path, aria: { label: \"Home\" } %>", 0, { attrs: [["aria-label", "Home"]] }
# `button_to` accepts the confirmation on the button (`data:`) and on the form
# it builds (`form: { data: … }`); Turbo honours both. The rest of `form:` has
# no attribute name on the control and keeps the sentinel it always had.
check_node "button_to's data: turbo_confirm sits beside its method:",
           "<%= button_to \"Sign out\", logout_path, method: :delete, data: { turbo_confirm: \"Sign out?\" } %>", 0,
           { kind: "link_to", name: "logout", attrs: [["method", "delete"], ["data-turbo-confirm", "Sign out?"]] }
check_node "button_to's form: { data: … } lands on the control; the rest of form: stays the sentinel",
           "<%= button_to \"Sign out\", logout_path, method: :delete, form: { data: { turbo_confirm: \"Sure?\" }, class: \"c\" } %>", 0,
           { kind: "link_to", name: "logout", attrs: [["method", "delete"], ["data-turbo-confirm", "Sure?"], ["form", "{...}"]] }
check_node "a form: carrying only data: leaves no form key behind",
           "<%= button_to \"Sign out\", logout_path, method: :delete, form: { data: { turbo_confirm: \"Sure?\" } } %>", 0,
           { kind: "link_to", attrs: [["method", "delete"], ["data-turbo-confirm", "Sure?"]] }
check_node "form_with's data: flattens onto the form node",
           "<%= form_with(url: \"/p\", data: { turbo: false }) do |f| %><% end %>", 0,
           { kind: "form", attrs: [["url", "/p"], ["data-turbo", "false"]] }
check_node "a builder field's data: flattens too",
           "<%= form_with(url: \"/x\") do |f| %><%= f.text_field :q, data: { controller: \"search\" } %><% end %>", 1,
           { kind: "form_field", attrs: [["data-controller", "search"]] }
# Only a hash of scalar literals is flattened. A value Rails would JSON-encode
# (a nested hash) or evaluate (an ivar, an interpolation) is left as it was,
# and the link is what it was before: not literal.
check "a data: value that is not a scalar literal leaves the link non-literal, as before",
      "<%= link_to \"x\", root_path, data: { params: { a: 1 } } %><%= link_to \"x\", root_path, data: { confirm: @msg } %><%= link_to \"x\", root_path, data: { confirm: \"Delete \#{@p.title}?\" } %><%= button_to \"x\", root_path, form: { data: { confirm: @msg } } %>",
      %w[route_helper_dynamic route_helper_dynamic route_helper_dynamic route_helper_dynamic]
# A nested hash under any OTHER key is not a Rails tag prefix and is reported
# as it always was.
check_node "a nested hash under a non-prefix key keeps the sentinel",
           "<%= link_to \"x\", root_path, html: { a: 1 } %>", 0, { kind: "link_to", attrs: [["html", "{...}"]] }
# NEW-4. ActionView 8.1.3.1's `tag_options` opens with `next if key.blank?`
# and repeats it inside the `data:`/`aria:` arms as `next if k.blank? ||
# v.nil?`, so Rails renders NO attribute for a blank key at either level. The
# nil half was already honoured; the blank half was not, and a blank key came
# through as `data-=""` / `=""` -- markup Rails never emits, and (for the
# outer case) an attribute with no name at all.
check_node "a blank key is omitted, at the top level and inside a data: hash",
           "<%= link_to \"x\", root_path, data: { \"\" => 1, ok: 2 }, \"\" => 3, id: \"b\" %>", 0,
           { kind: "link_to", attrs: [["data-ok", "2"], ["id", "b"]] }
# `blank?`, not `empty?`: ActiveSupport calls a whitespace-only String blank,
# and Rails drops that key exactly as it drops `""`.
check_node "a whitespace-only key is blank too",
           "<%= link_to \"x\", root_path, data: { \" \" => 1, ok: 2 } %>", 0,
           { kind: "link_to", attrs: [["data-ok", "2"]] }
# ActionView 8.1.3.1's `tag_option` runs the finished attribute NAME through
# `ERB::Util.xml_name_escape`, which rewrites every character XML forbids in a
# name to `_`. Without that, `data: { "with space" => "v" }` was reported as
# `data-with space`, which is not one attribute at all: a downstream HTML
# parser reads `data-with` and a nameless `space="v"`, and the converter wrote
# that into the target template.
check_node "an attribute name XML forbids is escaped the way ActionView escapes it",
           "<%= link_to \"x\", root_path, data: { \"with space\" => \"v\", \"q\\\"uote\" => \"w\" } %>", 0,
           { kind: "link_to", attrs: [["data-with_space", "v"], ["data-q_uote", "w"]] }
# Only the forbidden characters move: a dot and a digit are legal after the
# first character of an XML name, and Rails leaves them alone.
check_node "a dot and a digit inside a name survive the escape",
           "<%= link_to \"x\", root_path, data: { \"a.b2\" => \"v\" } %>", 0,
           { kind: "link_to", attrs: [["data-a.b2", "v"]] }

abort "#{$failures} templates failure(s)" if $failures > 0
puts "PASS: templates_test.rb"
