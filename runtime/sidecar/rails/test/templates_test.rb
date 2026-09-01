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

def check_presentation(label, src, expected)
  res = RailsTemplates.analyze(src, path: "app/views/posts/index.html.erb", i18n: I18N)
  got = res.slice(:parity_h1, :parity_h1_node, :parity_links, :parity_link_nodes)
  return if got == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

check_presentation "literal heading and links are explicit parity facts",
                   '<h1> About &amp; help </h1><a href="/posts">Posts</a><a href=/>Home</a>',
                   { parity_h1: "About & help", parity_h1_node: 0,
                     parity_links: ["/", "/posts"], parity_link_nodes: [0, 0] }
check_presentation "dynamic headings and hrefs are not guessed",
                   '<h1><%= @title %></h1><a href="<%= post_path(@post) %>">Post</a>',
                   { parity_h1: nil, parity_h1_node: nil, parity_links: [], parity_link_nodes: [] }
check_presentation "resolved i18n inside h1 is literal presentation evidence",
                   '<h1><%= t(".heading") %></h1>',
                   { parity_h1: "Posts", parity_h1_node: 0, parity_links: [], parity_link_nodes: [] }
check_presentation "presentation facts retain their source node",
                   '<a href="/outside">Outside</a><% if current_user %><h1>Account</h1><a href="/account">Account</a><% end %>',
                   { parity_h1: "Account", parity_h1_node: 2,
                     parity_links: ["/account", "/outside"], parity_link_nodes: [2, 0] }

check "yield and named yield", "<%= yield %><%= yield :head %><%= content_for?(:side) %>", %w[yield yield_named yield_named]
check_node "named yield carries its name", "<%= yield :head %>", 0, { name: "head" }
check_node "a named yield with a default keeps both branches explicit",
           "<%= content_for?(:x) ? yield(:x) : \"default\" %>", 0,
           { kind: "yield_named", name: "x", value: "default", dynamic: true }

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
FIELDS_FOR = "<%= form_with(url: \"/x\") do |f| %><%= f.fields_for :tags do |g| %><%= g.text_field :name %><% end %><% end %>"
check "fields_for introduces its nested builder", FIELDS_FOR,
      %w[form form_field form_field block_end block_end]
check_node "a fields_for child is a form field, not a local", FIELDS_FOR, 2,
           { kind: "form_field", name: "text_field", args: ["name"] }

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
check_node "component props literal", "<%= react_component(\"Hello\", { name: \"n\" }) %>", 0, { name: "Hello", attrs: [["name", "n", "string"]] }
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

# (b) A construct written entirely inside ONE tag contributes only the tag's
# own node. Its Ruby body is not a separately rendered template fragment, and
# no synthetic block_end with col:0 is emitted. The following tag keeps its
# own position and code.
check_positions "a self-contained block emits no synthetic body or block_end",
                "<% while x do end %><%= 2 %>",
                [["control", 1, 4], ["literal", 1, 25]]
check_node "the fragment after it keeps its own code", "<% while x do end %><%= 2 %>", 1, { code: "2", value: "2" }
check_node "a self-contained if reports the whole tag as its code", "<% if x then y end %>", 0,
           { kind: "control", code: "if x then y end" }
check "a self-contained call block does not leak its Ruby body", "<% items.each { |i| x } %>", %w[control]
check_positions "a multi-statement output tag points at its first expression",
                "<%= x; y %>", [["unknown", 1, 5]]

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

# ---------------------------------------------------------------------------
# #167 Stage 4 Task 1: the interactivity vocabulary.
#
# Rails writes three of the four interactive constructs as ORDINARY HTML, not
# as helper calls: `<div data-controller="reveal">`, `<turbo-frame id="x">`,
# `<div data-react-class="Chart">`. Stage 2 saw none of them -- the walker only
# classified Ruby fragments, and those tags live in the TEXT runs between them
# -- so a template's whole interactive layer was invisible to the migration and
# converted to inert markup with no finding to answer. The sidecar is the only
# place that can find them (nothing on the Zig side parses HTML), and it is the
# only place that can CLOSE them into regions: an element's extent is decided
# by depth-counting its own tag across the text runs that follow, which needs
# the block structure the walker already has.
# ---------------------------------------------------------------------------

def all_nodes(src, path: "app/views/posts/index.html.erb")
  res = RailsTemplates.analyze(src, path: path, i18n: I18N)
  raise "unexpected error #{res.inspect}" if res[:error]
  res[:nodes]
end

# (1) A `data-controller` tag is a `stimulus` node positioned at its `<`, and
# it carries exactly the four Stimulus attribute families -- `data-action`,
# `data-<id>-target`, `data-<id>-<name>-value`, `data-<id>-<name>-class`. An
# ordinary `class` is not one of them: the island binds behaviour, and copying
# presentation attributes into its props would make the port claim things the
# controller never read.
STIMULUS_TAG = "<div data-controller=\"reveal\" data-action=\"click->reveal#toggle\" " \
               "data-reveal-target=\"panel\" data-reveal-open-value=\"false\" " \
               "data-reveal-on-class=\"is-on\" class=\"c\">x</div>"
check "a data-controller element is a stimulus region", STIMULUS_TAG, %w[stimulus block_end]
check_node "a stimulus node carries its identifiers, its tag and its Stimulus attributes", STIMULUS_TAG, 0,
           { kind: "stimulus", name: "reveal", value: "div", output: false, line: 1, col: 1,
             code: "<div data-controller=\"reveal\" data-action=\"click->reveal#toggle\" " \
                   "data-reveal-target=\"panel\" data-reveal-open-value=\"false\" " \
                   "data-reveal-on-class=\"is-on\" class=\"c\">",
             attrs: [["data-action", "click->reveal#toggle"], ["data-reveal-target", "panel"],
                     ["data-reveal-open-value", "false"], ["data-reveal-on-class", "is-on"]] }
# `data-controller="reveal modal"` is two identifiers on one element; the
# value is kept VERBATIM so the reader splits it once, in one place.
check_node "several identifiers stay one verbatim value",
           "<div data-controller=\"reveal modal\">x</div>", 0, { kind: "stimulus", name: "reveal modal" }
# HTML5's tree builder drops a duplicate attribute and keeps the FIRST, so
# that is the value the browser hands Stimulus. Reporting the last would name
# a controller the page never instantiates.
check_node "a duplicate attribute reports the first occurrence, as HTML resolves it",
           "<div data-controller=\"first\" data-controller=\"second\">x</div>", 0,
           { kind: "stimulus", name: "first" }

# (2) A tag spanning two lines is positioned at the `<`, not at the attribute
# that qualified it.
check_node "a tag spanning two lines reports the line and column of its `<`",
           "<p>hi</p>\n<div\n  data-controller=\"reveal\">x</div>", 0,
           { kind: "stimulus", line: 2, col: 1 }
# The column comes from the text TOKEN's own source position (erb.rb's new
# `col:`). Prism can only report where `_buf << '…'` sits in the generated
# program, so without the token every element in every template would land on
# column 1 -- and every finding id derived from one would collide with the
# next element on the same line.
check_node "an element part-way along a line reports its own column",
           "<p>x</p><div data-controller=\"reveal\">y</div>", 0,
           { kind: "stimulus", line: 1, col: 9 }
check_node "a column after a newline counts from the start of that line",
           "a\n  <div data-controller=\"reveal\">y</div>", 0,
           { kind: "stimulus", line: 2, col: 3 }
# The discriminating case for the token: a run that does NOT begin at column
# 1, because an ERB tag preceded it. Counting from the run's first byte alone
# would report column 1 here.
check_node "a run that starts after a tag counts from the tag's end",
           "<%= 1 %><div data-controller=\"reveal\">y</div>", 1,
           { kind: "stimulus", line: 1, col: 9 }

# (3) A tag inside an HTML comment is not markup Rails renders, and a tag
# inside `<script>`/`<style>` is text, not an element. Reporting either would
# raise a finding an operator cannot act on and (worse) open an extent that
# never closes.
check "a commented-out element yields nothing", "<!-- <div data-controller=\"x\"> --><p>a</p>", []
check "an element inside <script> yields nothing",
      "<script>var s = '<div data-controller=\"x\">';</script><p>a</p>", []
check "an element inside <style> yields nothing",
      "<style>/* <div data-controller=\"x\"> */</style><p>a</p>", []

# (4) `<turbo-frame>` is recognised by its TAG NAME, and its `src`/`loading`
# are the two attributes the island needs; a frame with no `id` is dynamic
# (the id is the frame's identity, and Turbo requires one).
check_node "a turbo-frame element carries id, src and loading",
           "<turbo-frame id=\"latest\" src=\"/posts\" loading=\"lazy\"></turbo-frame>", 0,
           { kind: "turbo_frame", name: "latest", value: "turbo-frame",
             attrs: [["src", "/posts"], ["loading", "lazy"]], dynamic: false }
check_node "a turbo-frame with no id is dynamic",
           "<turbo-frame src=\"/posts\"></turbo-frame>", 0,
           { kind: "turbo_frame", name: nil, dynamic: true }

# (5) A React root's props are the JSON Rails' react-rails helper writes into
# `data-react-props`. A flat object of scalars becomes typed triples; anything
# else -- absent, unparseable, nested -- is `dynamic`, because the target's
# `:props` literal is typechecked and a nested value has no Ziggy spelling
# this stage emits.
check_node "a data-react-class element carries typed props",
           "<div data-react-class=\"Chart\" data-react-props='{\"a\":1,\"b\":\"x\",\"c\":true,\"d\":null}'></div>", 0,
           { kind: "component_root", name: "Chart",
             attrs: [["a", "1", "number"], ["b", "x", "string"], ["c", "true", "boolean"], ["d", "", "null"]],
             dynamic: nil }
check_node "nested React props are dynamic",
           "<div data-react-class=\"Chart\" data-react-props='{\"a\":{\"b\":1}}'></div>", 0,
           { kind: "component_root", name: "Chart", dynamic: true }
check_node "absent React props are dynamic",
           "<div data-react-class=\"Chart\"></div>", 0, { kind: "component_root", name: "Chart", dynamic: true }
check_node "unparseable React props are dynamic",
           "<div data-react-class=\"Chart\" data-react-props='not json'></div>", 0,
           { kind: "component_root", name: "Chart", dynamic: true }

# (6) Vue: named, and nothing else. Decision 7 makes it a blocker, so the node
# exists to be reported, never to be built from.
check_node "a data-vue-component element is a vue_root",
           "<div data-vue-component=\"Widget\"></div>", 0,
           { kind: "vue_root", name: "Widget", code: "<div data-vue-component=\"Widget\">" }

# (7) Extent (B11). The close is found by depth-counting the element's OWN tag
# name, so an inner `<div>` does not close an outer `<div data-controller>`.
# Without the count the region would end at the first `</div>`, and the island
# would wrap half its own markup.
NESTED = "<div data-controller=\"r\"><div>inner</div></div>"
check "a nested same-name element does not close the region early", NESTED, %w[stimulus block_end]
check_node "the block_end sits at the OUTER close tag", NESTED, 1,
           { kind: "block_end", code: "</div>", line: 1, col: 42, output: false }
# A void element cannot contain anything, so there is no extent to close and
# the node says so rather than swallowing the rest of the template.
check "a void element opens no region", "<input data-controller=\"r\"><p>after</p>", %w[stimulus]
check_node "a void element is missing", "<input data-controller=\"r\">", 0, { kind: "stimulus", missing: true }
check_node "a self-closing element is missing", "<div data-controller=\"r\"/>", 0, { kind: "stimulus", missing: true }
# ...and it is missing IMMEDIATELY, not merely by the time the template ends.
# A void element left on the open stack would be closed by the next same-name
# close tag -- `</input>` is not markup a browser honours, and a `/>` element
# has already ended -- which would hand an island an extent the page does not
# have. (Both of these pass on the wrong implementation if only the LAST node
# is inspected: `close_elements_at` marks everything still open at the end.)
check "an author-written close tag does not close a void element",
      "<input data-controller=\"r\">a</input>", %w[stimulus]
check "a stray close tag does not close a self-closed element",
      "<div data-controller=\"r\"/>\n<p>x</p>\n</div>", %w[stimulus]
# A close tag found at a DIFFERENT Ruby block depth does not close the
# element: the region would then straddle a branch, and the island would claim
# markup the template only renders conditionally.
check "a close inside a branch does not close an element opened outside it",
      "<div data-controller=\"r\">\n<% if x %>\n</div>\n<% end %>", %w[stimulus control block_end]
check_node "an element whose close is at another depth is missing",
           "<div data-controller=\"r\">\n<% if x %>\n</div>\n<% end %>", 0,
           { kind: "stimulus", missing: true }
check_node "an element with no close at all is missing",
           "<div data-controller=\"r\"><p>x</p>", 0, { kind: "stimulus", missing: true }
# An element orphaned when its own block ends is dropped THERE, not left on
# the stack until the template ends: two sibling branches are both "depth 1",
# so an element left over from the first would be closed by a tag in the
# second -- a region spanning two branches that never render together.
check "an element orphaned in one branch is not closed by the next branch's tag",
      "<% if a %><div data-controller=\"r\"><% end %><% if b %></div><% end %>",
      %w[control stimulus block_end control block_end]
# Fix round 1, I-1. An inner tag whose OWN attributes hold an ERB tag
# (`<div class="<%= cls %>">`, ubiquitous in real templates) is split across
# two text runs, so neither run holds a complete start tag and the opening-tag
# regex matches nothing. It still NESTS -- and before this it did not deepen
# the same-name count, so the outer element's region ended at the INNER
# `</div>`. That is a WRONG extent, not a missing one: B10's wrapping island
# would have closed halfway through the element it wraps, and a replacing one
# would have deleted the second half of it. Counting a bare `<name` even when
# the rest of the tag is out of reach makes the worst case a region that never
# closes -- `missing: true`, which B11 already refuses to offer `island` for.
ERB_SPLIT_INNER = "<div data-controller=\"outer\">\n  <div class=\"<%= cls %>\">inner</div>\n</div>\n"
check "an ERB-split inner tag does not end the region early", ERB_SPLIT_INNER, %w[stimulus local block_end]
check_node "the region closes at the OUTER tag, past the ERB-split inner one", ERB_SPLIT_INNER, 2,
           { kind: "block_end", line: 3, col: 1, code: "</div>" }
# Tag names are case-insensitive in HTML, and the fallback folds them the same
# way the whole-tag path does.
check_node "an ERB-split inner tag is matched case-insensitively, like a whole one",
           "<div data-controller=\"outer\">\n  <DIV class=\"<%= cls %>\">inner</DIV>\n</div>\n", 2,
           { kind: "block_end", line: 3, col: 1 }
# The degradation this buys, stated as a test so it is a decision and not a
# surprise: an ERB-split tag that never closes (or closes at another depth)
# leaves the element `missing` rather than closing it in the wrong place.
check_node "an ERB-split inner tag with no close leaves the region missing",
           "<div data-controller=\"outer\">\n  <div class=\"<%= cls %>\">inner\n", 0,
           { kind: "stimulus", missing: true }
# Regressions for the neighbouring shapes the count must NOT move: a complete
# inner tag (which the regex does see), a `<div/>`, which HTML5 treats as an
# ordinary start tag -- so it deepens the count and leaves the outer element
# unclosed, exactly as before this fix -- and a Ruby block, which is not a tag
# at all.
check_node "a complete inner tag still closes the region at the outer tag",
           "<div data-controller=\"outer\">\n  <div class=\"inner\">inner</div>\n</div>\n", 1,
           { kind: "block_end", line: 3, col: 1 }
check_node "a `<div/>` inside the region still leaves it missing",
           "<div data-controller=\"a\"><div/></div>", 0, { kind: "stimulus", missing: true }
check "a Ruby block inside an element does not disturb its extent",
      "<div data-controller=\"a\"><% if @x %>i<% end %></div>", %w[stimulus ivar block_end block_end]
# A `<` that starts no tag at all (`3 < 5`, unescaped, is everywhere in real
# templates) reaches the same fallback and must recover NO name: it neither
# raises nor deepens anything, and the region still closes where it should.
check_node "a bare `<` in text is not a tag and does not move the region",
           "<div data-controller=\"a\">\n  3 < 5\n</div>\n", 1,
           { kind: "block_end", line: 3, col: 1 }
# The depth guard inside the count, from BOTH callers. A same-name tag written
# inside a Ruby block is a tag the element's own `</div>` will never have to
# get past -- the block's own close already ended it (`close_elements_at`) --
# so counting it would leave the region open to the end of the template. The
# `<%= p %>` variant proves the ERB-split fallback shares the guard rather
# than counting at whatever depth it happens to be scanning at.
NESTED_IN_BLOCK = "<div data-controller=\"b\">\n  <% @posts.each do |p| %>\n" \
                  "    <div>x</div>\n  <% end %>\n</div>\n"
check_node "a nested tag inside a Ruby block does not deepen the region's count",
           NESTED_IN_BLOCK, 3, { kind: "block_end", line: 5, col: 1, code: "</div>" }
check_node "an ERB-split nested tag inside a Ruby block does not deepen it either",
           "<div data-controller=\"b\">\n  <% @posts.each do |p| %>\n" \
           "    <div class=\"<%= p %>\">x</div>\n  <% end %>\n</div>\n", 4,
           { kind: "block_end", line: 5, col: 1, code: "</div>" }
# The node is a MARKER: it consumes no bytes, so the converter still passes
# the author's own markup through. Splitting a run and losing a byte of it
# would silently delete markup from every page carrying an element.
# ...and the close tag stays INSIDE the region: the marker is placed after it,
# so `nodes[element..block_end]` spans the author's whole element. Cutting
# before the close tag instead would leave `</div>` outside the island the
# opening tag is inside of.
SPLITS = all_nodes("<div data-controller=\"r\">b</div>tail")
        .map { |n| n[:t] == "text" ? [:text, n[:text]] : [:code, n[:kind]] }
unless SPLITS == [[:code, "stimulus"], [:text, "<div data-controller=\"r\">b</div>"], [:code, "block_end"], [:text, "tail"]]
  warn "FAIL the block_end splits after the close tag: #{SPLITS.inspect}"
  $failures += 1
end

REJOIN = "<p>a</p><div data-controller=\"r\">b<span>c</span></div><p>d</p>"
joined = all_nodes(REJOIN).select { |n| n[:t] == "text" }.map { |n| n[:text] }.join
unless joined == REJOIN
  warn "FAIL split text runs re-join byte for byte\n  expected: #{REJOIN.inspect}\n  actual:   #{joined.inspect}"
  $failures += 1
end

# (8) `turbo_frame_tag` (the helper form) gains the same facts the HTML form
# carries: its options as attributes, and a `src:` written as a route helper
# resolved to a stem plus its literal arguments -- which is what lets the
# island fetch a URL this run can build. A `src:` it cannot read statically
# leaves the node dynamic rather than inventing one.
check_node "turbo_frame_tag with a literal src: helper names the route stem",
           "<%= turbo_frame_tag \"latest\", src: posts_path do %><% end %>", 0,
           { kind: "turbo_frame", name: "latest", value: "posts", args: [], attrs: [], dynamic: false }
check_node "a src: helper's literal arguments ride along",
           "<%= turbo_frame_tag \"latest\", src: post_path(1) do %><% end %>", 0,
           { kind: "turbo_frame", name: "latest", value: "post", args: ["1"] }
check_node "a src: helper with a non-literal argument is dynamic",
           "<%= turbo_frame_tag \"latest\", src: post_path(@post) do %><% end %>", 0,
           { kind: "turbo_frame", name: "latest", value: nil, dynamic: true }
check_node "a frame with no src: has no value and no src attribute",
           "<%= turbo_frame_tag \"static\" do %><% end %>", 0,
           { kind: "turbo_frame", name: "static", value: nil, attrs: [], dynamic: false }
check_node "a literal string src: stays in attrs and leaves the frame dynamic",
           "<%= turbo_frame_tag \"latest\", src: \"/posts\" do %><% end %>", 0,
           { kind: "turbo_frame", name: "latest", value: nil, attrs: [["src", "/posts"]], dynamic: true }
check_node "loading: :lazy arrives as an ordinary attribute",
           "<%= turbo_frame_tag \"latest\", src: posts_path, loading: :lazy do %><% end %>", 0,
           { kind: "turbo_frame", value: "posts", attrs: [["loading", "lazy"]] }

# (9) `react_component`'s literal props are typed triples too -- the same
# shape the HTML form produces, so one reader serves both.
check_node "react_component props are typed triples",
           "<%= react_component(\"Chart\", { series: \"a\", points: 3, on: true }) %>", 0,
           { kind: "component_root", name: "Chart",
             attrs: [["series", "a", "string"], ["points", "3", "number"], ["on", "true", "boolean"]] }

# (10) Shapes the port reads. A `locals:` hash of bare local variables is not
# LITERAL, but it is portable: `{ post: post }` says which local the partial
# is handed, which is exactly what a data island has to rename.
check_node "render locals of bare locals ride as attrs on render_dynamic",
           "<%= render partial: \"post\", locals: { post: post } %>", 0,
           { kind: "render_dynamic", name: "post", attrs: [["post", "post"]] }
check_node "a non-local locals value leaves render_dynamic without attrs",
           "<%= render partial: \"post\", locals: { post: @post } %>", 0,
           { kind: "render_dynamic", name: "post", attrs: nil }

# A dynamic route helper now says WHAT its arguments were, in source, and a
# `link_to` says what its text was -- the two things a port has to re-express.
# The name is the route STEM even when the link TEXT is what made it dynamic;
# before this, `link_to post.title, post_path(post)` reported the helper as
# `link_to`, which named no route at all.
check_node "a dynamic link names its route stem, its text and its arguments",
           "<%= link_to post.title, post_path(post) %>", 0,
           { kind: "route_helper_dynamic", name: "post", value: "post.title", args: ["post"] }
check_node "a bare dynamic route helper carries its argument sources",
           "<%= post_path(@post, anchor) %>", 0,
           { kind: "route_helper_dynamic", name: "post", args: ["@post", "anchor"] }
check_node "a block-form link retains its route helper target",
           "<%= link_to root_path do %>Home<% end %>", 0,
           { kind: "route_helper_dynamic", name: "root", value: "block body" }
check_node "a non-literal asset remains an asset with source arguments",
           "<%= image_tag @logo %>", 0,
           { kind: "asset", name: "image_tag", args: ["@logo"], dynamic: true }

# `turbo_stream_from "posts"` names the stream it subscribes to; without it
# the finding read "turbo-stream ``".
check_node "turbo_stream_from carries its literal stream name",
           "<%= turbo_stream_from \"posts\" %>", 0,
           { kind: "turbo_stream", name: "posts", value: "subscribe" }
check_node "a non-literal stream has no name",
           "<%= turbo_stream_from @post %>", 0,
           { kind: "turbo_stream", name: nil, value: "subscribe", dynamic: true }
check_node "a literal Turbo Stream action carries its action and target",
           "<%= turbo_stream.append \"posts\", partial: \"posts/post\" %>", 0,
           { kind: "turbo_stream", name: "posts", value: "append" }
check_node "a dynamic Turbo Stream target stays unsupported",
           "<%= turbo_stream.replace dom_id(@post), partial: \"posts/post\" %>", 0,
           { kind: "turbo_stream", name: nil, value: "replace", dynamic: true }
check_node "an unknown Turbo Stream action stays unsupported",
           "<%= turbo_stream.invoke \"posts\" %>", 0,
           { kind: "turbo_stream", name: "posts", value: nil, dynamic: true }

abort "#{$failures} templates failure(s)" if $failures > 0
puts "PASS: templates_test.rb"
