# Classifies every Ruby fragment of an ERB template into the closed
# vocabulary the design spec's "Fragment vocabulary" table defines, and
# returns ONE ordered node stream per template: text runs and classified
# code nodes, with block structure made explicit (`block_else`/`block_end`).
#
# How: the token stream from erb.rb is compiled into ONE Ruby program (text ->
# `_buf << '...';`, `<%=` -> `_out((...));`, `<%==` -> `_raw((...));`, code
# verbatim) and parsed ONCE with Prism. That is the only honest way to see
# block structure: a single `<% form_with ... do |f| %>` fragment is not valid
# Ruby on its own, but the whole program is, and `do ... end` / `if ... end`
# become real AST nesting instead of a guess. A program Prism rejects is a
# template whose fragments do not assemble -- reported as {error, line} and
# consumed as RAILS_TEMPLATE_PARSE_ERROR.
#
# The generated program is NOT line-aligned with the template (see `compile`);
# a `line_map` translates every position Prism reports back to a source line.
#
# Never evaluates anything. Templates under migration are untrusted input.
require "prism"
require_relative "erb"
require_relative "i18n"

module RailsTemplates
  REQUEST_STATE = %w[current_user session flash cookies params request signed_in? logged_in?
                     user_signed_in? current_account current_organization policy can? authorize].freeze
  ASSET_HELPERS = %w[image_tag image_path asset_path asset_url stylesheet_link_tag
                     javascript_include_tag favicon_link_tag audio_tag video_tag font_path].freeze
  IMPORTMAP_HELPERS = %w[javascript_importmap_tags turbo_include_tags].freeze
  CSRF_HELPERS = %w[csrf_meta_tags csrf_meta_tag csp_meta_tag].freeze
  CONTROL_CALLS = %w[each each_with_index map times each_slice].freeze

  # An output tag whose code ends in a block opener, recognised exactly as
  # ActionView's Erubi handler recognises it. See `compile`.
  BLOCK_EXPR = /\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\z/

  # Structural fragments (`<% end %>`, `<% else %>`, `<% when 1 %>`) produce
  # no classified node of their own but DO produce a token, so `block_end` /
  # `block_else` consume it -- see Walker#take_structural.
  BLOCK_END_TAG = /\A(end|\})\z/
  BLOCK_ELSE_TAG = /\A(else|elsif|when|in)\b/

  def self.analyze(src, path:, i18n:)
    tokens = RailsErb.scan(src)
    program, code_tokens, line_map, col_map = compile(tokens)
    result = Prism.parse(program)
    if result.failure?
      err = result.errors.first
      # The error's line is a GENERATED line; map it, and clamp it into the
      # template's own range so a failure in the compiler's own scaffolding
      # (the `def`/`end` wrapper) can never point past the last line.
      last = src.count("\n") + 1
      gen = err&.location&.start_line || 1
      return { error: err&.message || "parse error", line: (line_map[gen] || last).clamp(1, last) }
    end
    walker = Walker.new(path, i18n, code_tokens, line_map, col_map)
    walker.walk_program(result.value)
    { nodes: walker.nodes }
  rescue StandardError, SystemStackError => e
    # Same boundary rationale as controllers.rb: a bug in this walker, or a
    # SystemStackError out of Prism itself on pathologically nested but valid
    # source, must degrade to one unresolved template -- never take the batch
    # down. SystemStackError is named explicitly because it is not a
    # StandardError.
    { error: "#{e.class}: #{e.message}", line: 1 }
  end

  # Compiles the token stream to `[program, code_tokens, line_map]`.
  #
  # The whole program is wrapped in one method body because `yield` is a
  # PARSE error outside a method -- and `<%= yield %>` is in every Rails
  # layout, so without the wrapper the most common template in the app would
  # report RAILS_TEMPLATE_PARSE_ERROR.
  #
  # There is deliberately NO attempt to keep the generated program
  # line-aligned with the source (ruling R10). Alignment is unachievable and
  # silently lossy: every code fragment must be able to end in a Ruby comment
  # (`<% # note %>` is ordinary Rails), and a comment swallows whatever the
  # compiler puts after it on the same line -- its own `;`, the next
  # fragment, even the method's terminating `end`. That is a wrong ANSWER,
  # not an error: `<% # c %><%= 1 %>` compiled to one line yields `{nodes: []}`.
  #
  # So each code fragment gets a generated line of its OWN, terminated by a
  # newline, and `line_map[generated_line] -> source_line` records where each
  # one came from. Text runs stay single-quoted literals whose embedded
  # newlines are the source's own, so they advance both counters together.
  # Every position Prism reports is translated through the table before use.
  #
  # Ruling R17: `col_map` is the same translation for COLUMNS.
  # `col_map[generated_line] + <Prism's 0-based column>` is the true 1-based
  # source column of anything on that line. Before it existed, a node's column
  # came from the source TOKEN, which is honest only for the first statement
  # of a tag -- every later one fell back to `col: 0`, so
  # `<% number_to_currency(1); pluralize(2) %>` produced two findings with the
  # identical id `<code>.<path>.L1C0` and broke the uniqueness `findings.zig`'s
  # `lessThan` rests its total order on.
  def self.compile(tokens)
    out = +"def _zigapagos_template\n"
    code_tokens = []
    line_map = [nil, 1] # 1-based; generated line 1 is the method header
    col_map = [nil, 1]
    gen = 2
    # Byte offset of the next write within the CURRENT generated line. A text
    # run does not terminate its line (`text_source` adds no newline), so a
    # fragment following one on the same source line starts partway along the
    # generated line -- which shifts every Prism column on it by exactly this.
    gen_col = 0

    tokens.each do |t|
      code = t[:type] == :code
      code_tokens << t if code
      written = code ? "#{fragment_source(t)}\n" : text_source(t)
      out << written

      # A token may START midway through a generated line (text following a
      # text on the same line), so the first mapping is `||=` -- the fragment
      # that opened the line owns it. Newlines INSIDE the token are the
      # source's own and advance both counters; the terminator newline this
      # method adds after a code fragment advances only the generated one.
      line_map[gen] ||= t[:line]
      # Assigned, not `||=`d, for the mirror-image reason: a generated line
      # holds AT MOST ONE code fragment (every fragment terminates its own
      # line), and only a code fragment has columns worth recovering -- a text
      # run's node carries no column at all. So when a text run opened this
      # line, the fragment that follows it still owns the line's column story.
      # `t[:col] + 2 + indicator.length` is where the fragment's own source
      # text begins (past `<%` and the indicator); subtracting where it was
      # WRITTEN turns a generated column into a source one.
      col_map[gen] = t[:col] + 2 + t[:indicator].to_s.length - (gen_col + fragment_prefix_length(t)) if code
      (code ? t[:code] : t[:text]).count("\n").times do |i|
        gen += 1
        line_map[gen] = t[:line] + i + 1
        # A continuation line of a multi-line fragment (or of a text run) is
        # verbatim source: it begins at source column 1.
        col_map[gen] = 1
      end
      if code
        gen += 1
        gen_col = 0
      else
        last_nl = written.rindex("\n")
        gen_col = last_nl ? written.length - last_nl - 1 : gen_col + written.length
      end
    end
    out << "\nend"
    [out, code_tokens, forward_fill(line_map, gen + 2), col_map]
  end

  # A generated line with no token of its own belongs to the last fragment
  # that had one, so nothing Prism can point at maps to nil.
  def self.forward_fill(map, length)
    last = 1
    (1...length).each { |i| map[i].nil? ? map[i] = last : last = map[i] }
    map
  end

  def self.text_source(token)
    "_buf << '#{token[:text].gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")}';"
  end

  # `<%= form_with(model: @post) do |f| %>` cannot become
  # `_out((form_with(model: @post) do |f|));` -- that is not Ruby, the block
  # is left unclosed inside the parens. ActionView's Erubi handler emits the
  # command-call form instead, and so does this: `_outb <code>` with NO parens
  # and NO trailing `;`, so a `do ... end` binds to `_outb` and a `{ ... }`
  # binds to the inner call, and the matching `<% end %>` / `<% } %>` fragment
  # closes it. Every other output tag keeps the doubled parens, which is what
  # makes `<%= x if y %>` a valid argument rather than a syntax error.
  def self.fragment_source(token)
    block_expr = BLOCK_EXPR.match?(token[:code])
    case token[:indicator]
    when "=" then block_expr ? "_outb #{token[:code]}" : "_out((#{token[:code]}));"
    when "==" then block_expr ? "_rawb #{token[:code]}" : "_raw((#{token[:code]}));"
    else "#{token[:code]};"
    end
  end

  # How many bytes `fragment_source` writes BEFORE the fragment's own source
  # text. `compile`'s column map subtracts it: Prism reports a column inside
  # the GENERATED line, and an output tag's line opens with a call prefix that
  # has no counterpart in the template, so without this every `<%= %>` node
  # would report six columns too far right. All four prefixes above --
  # `_out((`, `_outb `, `_raw((`, `_rawb ` -- are six bytes; a code tag has
  # none. `templates_test.rb` pins this against `fragment_source` itself so
  # the two cannot drift apart silently.
  def self.fragment_prefix_length(token)
    case token[:indicator]
    when "=", "==" then 6
    else 0
    end
  end

  class Walker
    attr_reader :nodes

    def initialize(path, i18n, code_tokens, line_map, col_map)
      @path = path
      @i18n = i18n
      @nodes = []
      @line_map = line_map
      @col_map = col_map
      # Tokens by SOURCE line, consumed in walk order, so a node's :code comes
      # from the tag it was written as. (Its :col does NOT: see `emit`. A tag
      # can hold several statements, and only one of them can own the tag's
      # own text.)
      @tokens_by_line = code_tokens.group_by { |t| t[:line] }
      # Generated lines whose tag has already handed its token to a node --
      # see `take_token`.
      @tagged_lines = {}
      @form_builders = [] # block-param names of the form blocks now open
    end

    def walk_program(program)
      defn = program.statements&.body&.first
      walk_statements(defn.is_a?(Prism::DefNode) ? statements_of(defn.body) : [])
    end

    def walk_statements(stmts)
      stmts.each { |s| visit(s) }
    end

    private

    def visit(node)
      node = unwrap(node)
      line = src_line(node.location.start_line)
      if buf_append?(node)
        @nodes << { t: "text", text: node.arguments.arguments.first.unescaped, line: line }
        return
      end
      case out_kind(node)
      when :out then emit_output(node, classify(inner_arg(node), output: true))
      when :raw then emit_output(node, { kind: "raw", output: true })
      else emit_statement(node)
      end
    end

    # ---- statement-level (code fragments) --------------------------------

    # No `line` parameter: `emit` derives BOTH coordinates from the node whose
    # position it is reporting, so they can never come from two different
    # generated lines (which is reachable for an output tag -- see
    # `emit_output`).
    def emit_statement(node)
      case node
      when Prism::IfNode, Prism::UnlessNode
        emit(control_info(node.predicate, node.is_a?(Prism::IfNode) ? "if" : "unless"), node)
        walk_statements(statements_of(node.statements))
        sub = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        while sub
          block_else(sub)
          walk_statements(statements_of(sub.statements))
          # An `elsif` is itself an IfNode; an `else` ends the chain.
          sub = sub.is_a?(Prism::IfNode) ? sub.subsequent : nil
        end
        block_end(node)
      when Prism::CaseNode, Prism::CaseMatchNode
        emit(control_info(node.predicate, "case"), node)
        (node.conditions + [node.else_clause].compact).each do |branch|
          block_else(branch)
          walk_statements(statements_of(branch.statements))
        end
        block_end(node)
      when Prism::WhileNode, Prism::UntilNode
        emit(control_info(node.predicate, node.is_a?(Prism::WhileNode) ? "while" : "until"), node)
        walk_statements(statements_of(node.statements))
        block_end(node)
      when Prism::CallNode
        info = classify(node, output: false)
        emit(info, node)
        blk = command_block(node)
        walk_block(blk, info, node) if blk
      else
        emit(classify(node, output: false), node)
      end
    end

    # An output tag can carry a block too (see `RailsTemplates.fragment_source`).
    # Its body is the fragments between the tag and its `<% end %>` / `<% } %>`,
    # so they belong inside this node's block in the stream.
    #
    # The position comes from the tag's INNER expression, not from the
    # generated `_out((...))` call wrapped around it: the wrapper's own
    # position is the compiler's, six bytes to the left of anything the author
    # wrote (and, for a tag opened on one line and continued on the next, on a
    # different generated line entirely).
    def emit_output(node, info)
      emit(info, node, inner_arg(node))
      blk = command_block(node)
      walk_block(blk, info, node) if blk
    end

    # Finds the block a cross-fragment tag opened, wherever Ruby bound it.
    # A `do ... end` binds to the OUTERMOST call (`_outb`), but a brace block
    # binds to the INNERMOST command argument: in `_outb link_to root_path { ... }`
    # it hangs off `root_path`, two calls down. Looking only at `_outb` and its
    # immediate argument loses the block -- and losing it deletes every node
    # inside the tag from the stream and leaves the `<% } %>` token to be
    # mis-attributed to the next fragment.
    #
    # The walk stops at the first call written WITH parentheses, because a
    # parenthesised call's arguments were closed inside this fragment:
    # `<% foo(bar { |x| x }) %>` opens nothing that a later fragment closes.
    def command_block(node)
      n = node
      while n.is_a?(Prism::CallNode)
        return n.block if n.block.is_a?(Prism::BlockNode)
        break unless n.opening_loc.nil?
        n = n.arguments&.arguments&.last
      end
      nil
    end

    def walk_block(blk, info, node)
      # A form builder is only in scope inside its own block, and nested forms
      # nest, so this is a stack rather than a single name.
      @form_builders.push(block_param_name(blk)) if info[:kind] == "form"
      walk_statements(statements_of(blk.body))
      @form_builders.pop if info[:kind] == "form"
      block_end(node)
    end

    def block_end(node)
      line = src_line(node.location.end_line)
      tok = take_structural(line, BLOCK_END_TAG)
      @nodes << { t: "code", kind: "block_end", line: line, col: tok ? tok[:col] : 0, output: false, code: tok ? tok[:code].strip : "" }
    end

    def block_else(branch)
      line = src_line(branch.location.start_line)
      tok = take_structural(line, BLOCK_ELSE_TAG)
      @nodes << { t: "code", kind: "block_else", line: line, col: tok ? tok[:col] : 0, output: false, code: tok ? tok[:code].strip : "" }
    end

    # Ruling R2c: a branch is named by what it BRANCHES ON. `<% if
    # @post.errors.any? %>` is an `errors` finding and `<% if signed_in? %>` a
    # request_state one -- which is what a human porting the template needs to
    # see first. Only a predicate that classifies as nothing in particular (a
    # literal, a template local, an unrecognised call) leaves the statement as
    # plain `control`.
    GENERIC_PREDICATE = %w[literal local unknown].freeze
    private_constant :GENERIC_PREDICATE

    def control_info(predicate, name)
      info = predicate ? classify_inner(predicate) : nil
      return info if info && !GENERIC_PREDICATE.include?(info[:kind])
      { kind: "control", name: name }
    end

    # ---- expression classification -----------------------------------------

    def classify(node, output:)
      info = classify_inner(node)
      info[:output] = output
      info
    end

    def classify_inner(node)
      node = unwrap(node)
      case node
      when Prism::YieldNode
        args = positional(node.arguments)
        return { kind: "yield" } if args.empty?
        return { kind: "yield_named", name: literal(args.first) } if literal(args.first)
        return { kind: "unknown", name: "yield" }
      when Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode
        return { kind: "literal", value: literal(node).to_s }
      when Prism::InterpolatedStringNode
        return { kind: "literal", value: literal(node) } if literal(node)
      when Prism::InstanceVariableReadNode
        # Ruling R9: an ivar's `name` KEEPS the `@` -- it names the variable,
        # and the finding reads "request-time state `@posts`".
        return { kind: "ivar", name: node.name.to_s }
      when Prism::ConstantReadNode
        return { kind: "request_state", name: "Current" } if node.name == :Current
      when Prism::LocalVariableReadNode
        return { kind: "local", name: node.name.to_s }
      when Prism::CallNode
        return classify_call(node)
      end
      state_or(node, { kind: "unknown", name: node.class.name.split("::").last })
    end

    def classify_call(node)
      name = node.name.to_s
      args = positional(node.arguments)
      opts = hash_opts(node.arguments)
      return classify_method_call(node, name, node.receiver, args, opts) if node.receiver

      return { kind: "request_state", name: name } if REQUEST_STATE.include?(name) || name.start_with?("current_")
      case name
      when "content_for?"
        return { kind: "yield_named", name: literal(args.first) } if literal(args.first)
      when "content_for"
        return { kind: "content_for", name: literal(args.first).to_s, value: (args[1] ? literal(args[1]) : nil) }.compact if literal(args.first)
      when "provide"
        return { kind: "content_for", name: literal(args.first).to_s, value: literal(args[1]) } if literal(args.first) && literal(args[1])
      when "render"
        return classify_render(args, opts)
      when "link_to", "button_to"
        return classify_link(args, opts)
      when "raw"
        return { kind: "raw" }
      when "t", "translate"
        return classify_i18n(args)
      when "form_with", "form_for", "form_tag"
        return classify_form(args, opts)
      when "turbo_frame_tag"
        return { kind: "turbo_frame", name: literal(args.first), dynamic: literal(args.first).nil? }.compact
      when "turbo_stream_from"
        return { kind: "turbo_stream" }
      when "react_component"
        return classify_component(args)
      end
      return { kind: "importmap", name: name } if IMPORTMAP_HELPERS.include?(name)
      return { kind: "csrf", name: name } if CSRF_HELPERS.include?(name)
      if ASSET_HELPERS.include?(name)
        return { kind: "asset", name: name, args: literal_args(args), attrs: literal_attrs(opts) } if args.empty? || literal(args.first)
        return state_or(node, { kind: "unknown", name: name })
      end
      if name.end_with?("_path", "_url")
        stem = name.sub(/_(path|url)\z/, "")
        return { kind: "route_helper", name: stem, args: literal_args(args), attrs: literal_attrs(opts) } if all_literal?(args) && all_literal_opts?(opts)
        return { kind: "route_helper_dynamic", name: stem }
      end
      # A bare identifier Prism could not prove is a method call is a template
      # local (`post`). Checked LAST of the receiverless cases, because
      # `posts_path` is a bare identifier too and is a route helper, not a local.
      return { kind: "local", name: name } if node.variable_call?

      { kind: "unknown", name: name }
    end

    def classify_method_call(node, name, recv, args, opts)
      return { kind: "raw" } if name == "html_safe"
      return classify_i18n(args) if recv.is_a?(Prism::ConstantReadNode) && recv.name == :I18n && %w[t translate].include?(name)
      return { kind: "turbo_stream" } if recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.name == :turbo_stream
      return { kind: "errors", name: receiver_root_name(recv) } if chain_calls?(node, "errors")
      if form_builder?(recv)
        return { kind: "form_field", name: name, args: literal_args(args), attrs: literal_attrs(opts) }
      end
      return state_or(recv, { kind: "control", name: name }) if CONTROL_CALLS.include?(name) && node.block
      # Whatever the chain does, it is rooted in either a template local or
      # something unrecognised -- and request state or an ivar ANYWHERE in it
      # outranks both.
      state_or(node, root_is_local?(recv) ? { kind: "local", name: receiver_root_name(recv) } : { kind: "unknown", name: name })
    end

    # `f` in `form_with ... do |f|` reaches the walker as a LocalVariableReadNode
    # (the block param is a real local in the compiled program); a builder used
    # outside any block Prism sees would be a bare-identifier call instead.
    def form_builder?(recv)
      case recv
      when Prism::LocalVariableReadNode then @form_builders.include?(recv.name.to_s)
      when Prism::CallNode then recv.receiver.nil? && recv.variable_call? && @form_builders.include?(recv.name.to_s)
      else false
      end
    end

    def classify_render(args, opts)
      target = opts["partial"] || (args.first.is_a?(Prism::StringNode) ? args.first : nil)
      # `render @post` and friends: the TARGET is runtime state, which is
      # exactly what render_dynamic says -- so no state_or here, an `ivar`
      # node would lose the fact that this is a partial at all.
      return { kind: "render_dynamic", name: safe_slice(args.first) } if target.nil?
      lit = literal(target)
      return { kind: "render_dynamic", name: safe_slice(target) } if lit.nil?
      return { kind: "render_dynamic", name: lit } if opts["collection"] || opts["object"] || opts["layout"]
      if opts["locals"]
        pairs = literal_pairs(opts["locals"])
        return { kind: "render_dynamic", name: lit } if pairs.nil?
        return { kind: "render_partial_locals", name: lit, attrs: pairs }
      end
      { kind: "render_partial", name: lit }
    end

    def classify_link(args, opts)
      text, target = args[0], args[1]
      return { kind: "route_helper_dynamic", name: "link_to" } unless literal(text)
      if target.is_a?(Prism::CallNode) && target.receiver.nil? && target.name.to_s.end_with?("_path", "_url")
        stem = target.name.to_s.sub(/_(path|url)\z/, "")
        targs = positional(target.arguments)
        if all_literal?(targs) && all_literal_opts?(opts)
          return { kind: "link_to", name: stem, args: [literal(text)] + literal_args(targs), attrs: literal_attrs(opts) }
        end
        # Same reasoning as classify_render: the route is the finding, and
        # route_helper_dynamic already says its argument is runtime state.
        return { kind: "route_helper_dynamic", name: stem }
      end
      return { kind: "link_to", name: nil, args: [literal(text), literal(target)], attrs: literal_attrs(opts) } if literal(target) && all_literal_opts?(opts)
      { kind: "route_helper_dynamic", name: "link_to" }
    end

    def classify_i18n(args)
      key = literal(args.first)
      return { kind: "unknown", name: "t" } if key.nil?
      full = RailsI18n.expand_lazy(key, @path)
      value = @i18n.lookup(full)
      value ? { kind: "i18n", name: full, value: value } : { kind: "i18n", name: full, missing: true }
    end

    def classify_form(args, opts)
      model = opts["model"] || (args.first.is_a?(Prism::InstanceVariableReadNode) ? args.first : nil)
      info = { kind: "form", attrs: literal_attrs(opts.reject { |k, _| k == "model" }) }
      if model.is_a?(Prism::InstanceVariableReadNode)
        # Ruling R9: a form's `name` is the model's PARAM KEY as Rails derives
        # it (`post` from `@post`), not the variable -- unlike an ivar node.
        info[:name] = model.name.to_s.delete_prefix("@")
        info[:dynamic] = true
      elsif model
        info[:name] = safe_slice(model)
        info[:dynamic] = true
      end
      info
    end

    def classify_component(args)
      name = literal(args.first)
      return { kind: "unknown", name: "react_component" } if name.nil?
      props = args[1]
      return { kind: "component_root", name: name, attrs: [] } if props.nil?
      pairs = literal_pairs(props)
      pairs ? { kind: "component_root", name: name, attrs: pairs } : { kind: "component_root", name: name, dynamic: true }
    end

    # Request-time state or an ivar ANYWHERE inside `node` wins over a GENERIC
    # fallback (`unknown`, `local`, `control`) -- that is the finding a human
    # needs first, and the #166 spike's 54% lexical precision is why it is
    # decided from the AST. Callers that already reached a specific kind
    # (route_helper_dynamic, render_dynamic) do NOT route through here: for
    # those, "the argument is runtime state" is what the kind already means.
    def state_or(node, fallback)
      return fallback unless node
      found = nil
      each_descendant(node) do |n|
        case n
        when Prism::InstanceVariableReadNode
          found ||= { kind: "ivar", name: n.name.to_s }
        when Prism::CallNode
          nm = n.name.to_s
          return { kind: "request_state", name: nm } if n.receiver.nil? && (REQUEST_STATE.include?(nm) || nm.start_with?("current_"))
        when Prism::ConstantReadNode
          return { kind: "request_state", name: "Current" } if n.name == :Current
        end
      end
      found || fallback
    end

    # ---- emission ---------------------------------------------------------

    # `output: false` is in the base hash, not left to the callers: every code
    # node in the stream carries the key, and only `classify` knows to set it
    # true (a statement fragment never outputs).
    #
    # `pos` is the node the POSITION is read from, `node` the one its source
    # text falls back to; they differ for an output tag (see `emit_output`).
    # Both coordinates come from `pos`, mapped back through `compile`'s two
    # tables -- never from the token, which can only ever describe the tag as a
    # whole and therefore reported `col: 0` for every statement in it after the
    # first (ruling R17).
    def emit(info, node, pos = node)
      loc = pos.location
      line = src_line(loc.start_line)
      tok = take_token(line, loc.start_line)
      @nodes << { t: "code", line: line, col: src_col(loc.start_line, loc.start_column), output: false,
                  code: (tok ? tok[:code].strip : safe_slice(pos)) }.merge(info)
    end

    # One token per TAG, not per node. A tag holding several statements emits
    # several nodes, and before this gate every one after the first shifted a
    # token belonging to a LATER tag onto itself -- stealing that tag's `code`
    # text and leaving it with none. A generated line holds at most one code
    # fragment (`RailsTemplates.compile`), so the generated line IS the tag
    # identity this needs; the source line is not (several tags share one).
    def take_token(line, generated)
      return nil if @tagged_lines[generated]
      @tagged_lines[generated] = true
      (@tokens_by_line[line] || []).shift
    end

    # Ruling R10: Prism reports positions in the GENERATED program, which is
    # not line-aligned with the template. Every one of them -- statement
    # starts, block ends, branch starts -- goes through here before it is used
    # as a line number or as a key into the token queue.
    def src_line(generated)
      @line_map[generated] || @line_map.compact.last || 1
    end

    # Ruling R17's column half: `column` is Prism's own 0-based offset within
    # the generated line, and `col_map` says where that line's first byte sits
    # in the template. `1` is the fallback for a generated line no code
    # fragment wrote (the method wrapper, a line a text run's newlines opened)
    # -- nothing on such a line has a column to recover, and "column 1" is the
    # honest answer for source that starts at the beginning of a line.
    def src_col(generated, column)
      (@col_map[generated] || 1) + column
    end

    # A structural fragment's token is consumed only when the next token on
    # that line really is one. It must be consumed: tokens are matched to nodes
    # by line in walk order, so an unconsumed `<% end %>` would shift every
    # later node on that line onto the wrong fragment (a form's `<% end %>` and
    # an `if`'s share line 1 in a one-line template). And it must be checked
    # first: a self-contained `<% if x then y end %>` has an `end` with no
    # token of its own, and swallowing the NEXT fragment's token there would
    # misalign everything after it instead.
    def take_structural(line, pattern)
      toks = @tokens_by_line[line]
      return nil unless toks&.first && pattern.match?(toks.first[:code].strip)
      toks.shift
    end

    # ---- helpers -----------------------------------------------------------

    def buf_append?(node)
      node.is_a?(Prism::CallNode) && node.name == :<< && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :_buf &&
        node.arguments&.arguments&.first.is_a?(Prism::StringNode)
    end

    def out_kind(node)
      return nil unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments&.arguments&.length == 1
      case node.name
      when :_out, :_outb then :out
      when :_raw, :_rawb then :raw
      end
    end

    def inner_arg(node)
      unwrap(node.arguments.arguments.first)
    end

    # `_out((x));` hands the walker a ParenthesesNode around a one-statement
    # StatementsNode. The doubled parens are what keeps `<%= x if y %>` a valid
    # argument, so they are stripped here rather than not emitted.
    def unwrap(node)
      return node unless node.is_a?(Prism::ParenthesesNode)
      body = node.body
      return node unless body.is_a?(Prism::StatementsNode) && body.body.length == 1
      body.body.first
    end

    def positional(arguments)
      return [] unless arguments
      arguments.arguments.reject { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::BlockArgumentNode) }
    end

    def hash_opts(arguments)
      return {} unless arguments
      h = arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
      return {} unless h
      h.elements.each_with_object({}) do |e, acc|
        next unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        acc[k.to_s] = e.value if k
      end
    end

    def literal(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::SymbolNode then node.unescaped
      when Prism::IntegerNode then node.value.to_s
      when Prism::FloatNode then node.value.to_s
      when Prism::TrueNode then "true"
      when Prism::FalseNode then "false"
      when Prism::NilNode then ""
      when Prism::InterpolatedStringNode
        node.parts.all? { |p| p.is_a?(Prism::StringNode) } ? node.parts.map(&:unescaped).join : nil
      end
    end

    def all_literal?(nodes) = nodes.all? { |n| literal(n) }
    def all_literal_opts?(opts) = opts.values.all? { |v| literal(v) || literal_pairs(v) }
    def literal_args(nodes) = nodes.map { |n| literal(n) }

    def literal_attrs(opts)
      opts.map { |k, v| [k, literal(v) || (literal_pairs(v) ? "{...}" : nil)] }.select { |_, v| v }
    end

    # A HashNode/KeywordHashNode whose keys and values are all literals -> [[k, v], ...]; else nil.
    def literal_pairs(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      node.elements.map do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        v = literal(e.value)
        return nil if k.nil? || v.nil?
        [k.to_s, v]
      end
    end

    def chain_calls?(node, method_name)
      n = node
      while n.is_a?(Prism::CallNode)
        return true if n.name.to_s == method_name
        n = n.receiver
      end
      false
    end

    def receiver_root_name(node)
      n = chain_root(node)
      case n
      when Prism::LocalVariableReadNode, Prism::CallNode, Prism::InstanceVariableReadNode then n.name.to_s
      else safe_slice(n)
      end
    end

    def root_is_local?(node)
      n = chain_root(node)
      n.is_a?(Prism::LocalVariableReadNode) || (n.is_a?(Prism::CallNode) && n.receiver.nil? && n.variable_call?)
    end

    def chain_root(node)
      n = node
      n = n.receiver while n.is_a?(Prism::CallNode) && n.receiver
      n
    end

    def block_param_name(block)
      req = block.parameters&.parameters&.requireds&.first
      req.respond_to?(:name) ? req.name.to_s : nil
    end

    def statements_of(body)
      case body
      when Prism::StatementsNode then body.body
      when Prism::BeginNode then body.statements&.body || []
      when nil then []
      else [body]
      end
    end

    def each_descendant(node, &blk)
      return unless node.respond_to?(:compact_child_nodes)
      blk.call(node)
      node.compact_child_nodes.each { |c| each_descendant(c, &blk) }
    end

    def safe_slice(node)
      node.slice
    rescue StandardError
      "?"
    end
  end
  private_constant :Walker
end
