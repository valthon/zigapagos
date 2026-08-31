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
require "json"
require "cgi"
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
    program, code_tokens, line_map, col_map, text_tokens = compile(tokens)
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
    walker = Walker.new(path, i18n, code_tokens, line_map, col_map, text_tokens)
    walker.walk_program(result.value)
    presentation = presentation_facts(walker.nodes)
    {
      nodes: walker.nodes,
      parity_h1: presentation[:h1],
      parity_h1_node: presentation[:h1_node],
      parity_links: presentation[:links],
      parity_link_nodes: presentation[:link_nodes],
    }
  rescue StandardError, SystemStackError => e
    # Same boundary rationale as controllers.rb: a bug in this walker, or a
    # SystemStackError out of Prism itself on pathologically nested but valid
    # source, must degrade to one unresolved template -- never take the batch
    # down. SystemStackError is named explicitly because it is not a
    # StandardError.
    { error: "#{e.class}: #{e.message}", line: 1 }
  end

  # Static browser-visible facts for Stage 5 parity. Code tokens become a NUL
  # barrier, so a heading or attribute split by ERB is dynamic and cannot
  # accidentally match across the gap. This sidecar is already the template's
  # HTML-aware boundary; Zig receives facts and never reparses emitted HTML.
  def self.presentation_facts(nodes)
    marker = /\u0001(\d+)\u0002/
    text = nodes.each_with_index.map do |node, index|
      prefix = "\u0001#{index}\u0002"
      if node[:t] == "text"
        prefix + node[:text]
      elsif node[:output] && %w[literal i18n].include?(node[:kind]) && node[:value]
        prefix + CGI.escapeHTML(node[:value].to_s)
      elsif %w[stimulus turbo_frame component_root vue_root block_end].include?(node[:kind])
        prefix
      else
        prefix + "\0"
      end
    end.join
    text = text.gsub(/<!--.*?-->/m, "")
    text = text.gsub(%r{<(script|style)\b[^>]*>.*?</\1\s*>}im, "")

    node_before = lambda do |offset|
      text[0...offset].scan(marker).last&.first&.to_i
    end

    heading = nil
    heading_node = nil
    if (m = /<h1\b[^>]*>([^<\0]*)<\/h1\s*>/im.match(text))
      heading_node = node_before.call(m.begin(0))
      heading = CGI.unescapeHTML(m[1].gsub(marker, "")).gsub(/\s+/, " ").strip
      heading = nil if heading.empty?
      heading_node = nil if heading.nil?
    end

    links = []
    text.to_enum(:scan, /<a\b([^>\0]*)>/im).each do
      match = Regexp.last_match
      attrs = match[1].gsub(marker, "")
      href = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/i.match(attrs)
      links << [CGI.unescapeHTML(href.captures.compact.first), node_before.call(match.begin(0))] if href
    end
    links = links.uniq.sort_by { |value, node| [value, node || -1] }
    { h1: heading, h1_node: heading_node, links: links.map(&:first), link_nodes: links.map(&:last) }
  end

  # Compiles the token stream to
  # `[program, code_tokens, line_map, col_map, text_tokens]`.
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
    # Text tokens by the generated line their `_buf << '...'` statement opens.
    # A code fragment always terminates its own generated line and a `flush`
    # never emits two text tokens in a row, so that line identifies exactly
    # one text token -- which is the only carrier of a text run's true source
    # COLUMN (`line_map`/`col_map` describe fragments, and a text run's
    # generated column is `_buf << '` plus whatever escaping did).
    text_tokens = {}
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
      text_tokens[gen] = t unless code
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
    [out, code_tokens, forward_fill(line_map, gen + 2), col_map, text_tokens]
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

    def initialize(path, i18n, code_tokens, line_map, col_map, text_tokens = {})
      @path = path
      @i18n = i18n
      @nodes = []
      @line_map = line_map
      @col_map = col_map
      @text_tokens = text_tokens
      # Ruby block nesting, so an element's close tag is only accepted where
      # its opening tag was (B11): a `</div>` inside `<% if x %>` closes
      # nothing that was opened outside the branch, because a region that
      # straddles a branch is not a region the converter can wrap.
      @block_depth = 0
      # Elements whose extent is still open: `{name, depth, count, node}`.
      # `count` is the same-name nesting depth, so an inner `<div>` does not
      # let the first `</div>` close a `<div data-controller>`.
      @open_elements = []
      # Set while inside a comment or a raw-text element, so a tag written
      # inside one is text and not markup. Carried ACROSS text runs: an ERB
      # tag inside a `<script>` body splits it into several runs.
      @skip_until = nil
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
      # Anything still open when the template ends never found its close tag,
      # so it has no extent -- which is the whole difference between a region
      # an island can wrap and one it cannot (B11).
      close_elements_at(0)
    end

    def walk_statements(stmts)
      stmts.each { |s| visit(s) }
    end

    private

    def visit(node)
      node = unwrap(node)
      line = src_line(node.location.start_line)
      if buf_append?(node)
        tok = @text_tokens[node.location.start_line]
        emit_text_run(node.arguments.arguments.first.unescaped, tok ? tok[:line] : line, tok ? tok[:col] : 1)
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
        with_block_depth { walk_statements(statements_of(node.statements)) }
        sub = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        while sub
          block_else(sub)
          with_block_depth { walk_statements(statements_of(sub.statements)) }
          # An `elsif` is itself an IfNode; an `else` ends the chain.
          sub = sub.is_a?(Prism::IfNode) ? sub.subsequent : nil
        end
        block_end(node)
      when Prism::CaseNode, Prism::CaseMatchNode
        emit(control_info(node.predicate, "case"), node)
        (node.conditions + [node.else_clause].compact).each do |branch|
          block_else(branch)
          with_block_depth { walk_statements(statements_of(branch.statements)) }
        end
        block_end(node)
      when Prism::WhileNode, Prism::UntilNode
        emit(control_info(node.predicate, node.is_a?(Prism::WhileNode) ? "while" : "until"), node)
        with_block_depth { walk_statements(statements_of(node.statements)) }
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
      with_block_depth { walk_statements(statements_of(blk.body)) }
      @form_builders.pop if info[:kind] == "form"
      block_end(node)
    end

    # Ruby block nesting for the element extents (B11). An element still open
    # when its own block ends is orphaned: a close tag found afterwards sits
    # at another depth, and accepting it would make the region straddle the
    # branch. So it is dropped here with `missing: true` rather than left to
    # be closed by the wrong tag.
    def with_block_depth
      @block_depth += 1
      yield
    ensure
      close_elements_at(@block_depth)
      @block_depth -= 1
    end

    def close_elements_at(depth)
      while (e = @open_elements.last) && e[:depth] >= depth
        @open_elements.pop
        e[:node][:missing] = true
      end
    end

    # ---- element scan of text runs -----------------------------------------
    #
    # Rails writes three of the four interactive constructs as ORDINARY HTML:
    # `<div data-controller="reveal">`, `<turbo-frame id="x" src="/posts">`,
    # `<div data-react-class="Chart" data-react-props='…'>` (and its Vue
    # sibling). They are not Ruby fragments, so the Prism walk above cannot
    # see them -- and nothing on the Zig side parses HTML. This is the one
    # place that has both halves: the text runs AND the block structure an
    # extent has to be measured against.
    #
    # The tag grammar is HTML5's start-tag production, cut down to what a
    # template can contain: a name, then attributes with double-quoted,
    # single-quoted or unquoted values. It is a scanner, not a parser --
    # nothing here builds a tree, and nothing here needs to.

    # `\G`, not `\A`: both are matched at an OFFSET into the run
    # (`match(text, lt)`), so anchoring to the start of the string would mean
    # slicing a fresh remainder for every `<` in the template.
    ELEMENT_OPEN = /\G<([A-Za-z][A-Za-z0-9:-]*)((?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>`]*))?)*)\s*(\/?)>/m
    ELEMENT_CLOSE = %r{\G</([A-Za-z][A-Za-z0-9:-]*)\s*>}m
    # Just the NAME of a start tag: what is left of one whose attributes hold
    # an ERB tag, so the run ends before the `>`. See `scan_text_run`.
    ELEMENT_NAME = /\G<([A-Za-z][A-Za-z0-9:-]*)/
    ATTRIBUTE = /([^\s"'>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>`]+)))?/
    # Elements whose content is text, not markup: a `<div data-controller>`
    # written inside one is a string, and reporting it would raise a finding
    # about markup the browser never builds.
    RAW_TEXT = %w[script style].freeze
    # HTML void elements. A void element has no content and no close tag, so
    # there is no extent to find -- `missing: true`, immediately.
    VOID_ELEMENTS = %w[input img br hr meta link area base col embed source track wbr].freeze
    # The four Stimulus attribute families the port reads: the action
    # descriptors, the targets, the values and the classes. Everything else on
    # the tag (`class`, `id`, an author's own `data-*`) is presentation the
    # controller never saw, and copying it into an island's props would make
    # the port claim behaviour it does not have.
    STIMULUS_ATTR = /\Adata-action\z|\Adata-.+-target\z|\Adata-.+-.+-value\z|\Adata-.+-.+-class\z/
    private_constant :ELEMENT_OPEN, :ELEMENT_CLOSE, :ELEMENT_NAME, :ATTRIBUTE, :RAW_TEXT, :VOID_ELEMENTS,
                     :STIMULUS_ATTR

    # Emits one text run, split at every element node and every close tag that
    # ends an extent. An element node is a MARKER: it consumes no bytes, so
    # the emitted text nodes still concatenate to the run byte for byte and
    # the converter passes the author's own markup through. A `block_end` is
    # placed AFTER the close tag, so `nodes[element..block_end]` spans the
    # whole element -- opening tag, body and close tag.
    def emit_text_run(text, line, col)
      cuts = scan_text_run(text, line, col)
      return @nodes << { t: "text", text: text, line: line } if cuts.empty?

      pos = 0
      cuts.each do |cut|
        @nodes << { t: "text", text: text[pos...cut[:at]], line: advance_pos(line, col, text[0, pos])[0] } if cut[:at] > pos
        @nodes << cut[:node]
        pos = cut[:at]
      end
      @nodes << { t: "text", text: text[pos..], line: advance_pos(line, col, text[0, pos])[0] } if pos < text.length
    end

    # `[{at:, node:}, ...]` in offset order: where the run is split and what
    # goes in the gap. Also carries the extent bookkeeping, because both need
    # the same left-to-right tag scan and doing it twice would let the two
    # disagree about what is inside a comment.
    def scan_text_run(text, line, col)
      cuts = []
      i = 0
      while i < text.length
        if @skip_until
          m = @skip_until.match(text, i)
          # No terminator in THIS run: the comment/raw element continues into
          # the next one, and the state stays set.
          break unless m
          @skip_until = nil
          i = m.end(0)
          next
        end
        lt = text.index("<", i)
        break unless lt
        if text[lt, 4] == "<!--"
          @skip_until = /-->/m
          i = lt + 4
          next
        end
        if (m = ELEMENT_CLOSE.match(text, lt))
          i = lt + m[0].length
          cut = close_element(m[1].downcase, m[0], line, col, text, lt, i)
          cuts << cut if cut
          next
        end
        unless (m = ELEMENT_OPEN.match(text, lt))
          # A start tag this run cannot see the end of. Almost always one
          # whose attributes hold an ERB tag -- `<div class="<%= cls %>">` is
          # ubiquitous -- which splits the run mid-tag, so no run holds a
          # complete tag and the grammar above matches nothing.
          #
          # It still NESTS, and that is the half that must not be lost: a
          # tracked `<div data-controller>` whose count never learns about the
          # inner `<div` ends its region at the INNER `</div>`, which is a
          # WRONG extent, not a missing one -- B10's wrapping island closes
          # halfway through the element it wraps, and a replacing one deletes
          # the rest of it. Counting the bare name instead makes the worst
          # case an element whose count never returns to zero, i.e.
          # `missing: true`, which B11 already refuses to offer an extent-
          # needing choice for. Deliberately one-sided: the CLOSE side is left
          # alone, so a split close tag degrades the same conservative way.
          bump_open_elements(ELEMENT_NAME.match(text, lt)&.[](1)&.downcase)
          i = lt + 1
          next
        end
        name = m[1].downcase
        i = lt + m[0].length
        if RAW_TEXT.include?(name)
          @skip_until = /<\/#{name}[^>]*>/im
          next
        end
        cut = open_element(name, m, line, col, text, lt)
        cuts << cut if cut
      end
      cuts
    end

    # A same-name tag deepens every open element's count first (so the tag
    # cannot close the element it is nested in), THEN this tag becomes an open
    # element of its own if it qualifies.
    def open_element(name, m, line, col, text, lt)
      bump_open_elements(name)
      info = element_info(name, parse_attrs(m[2]))
      return nil unless info

      l, c = advance_pos(line, col, text[0, lt])
      node = { t: "code", line: l, col: c, output: false, code: m[0] }.merge(info)
      if VOID_ELEMENTS.include?(name) || m[3] == "/"
        node[:missing] = true
      else
        @open_elements << { name: name, depth: @block_depth, count: 1, node: node }
      end
      { at: lt, node: node }
    end

    # Every tracked element of this name at this block depth is now one level
    # deeper, so its own close tag is not the next `</name>` but the one after
    # the nested element's. A `nil` name (the caller recovered none: `<` not
    # followed by a letter) matches nothing -- every tracked element's name
    # came from a matched tag -- so no `nil` guard is needed here, and one
    # would be a line no test could ever fail on.
    def bump_open_elements(name)
      @open_elements.each { |e| e[:count] += 1 if e[:depth] == @block_depth && e[:name] == name }
    end

    def close_element(name, src, line, col, text, lt, after)
      idx = @open_elements.rindex { |e| e[:depth] == @block_depth && e[:name] == name }
      return nil unless idx
      e = @open_elements[idx]
      e[:count] -= 1
      return nil if e[:count] > 0
      @open_elements.delete_at(idx)
      l, c = advance_pos(line, col, text[0, lt])
      # Positioned at the `<` of the close tag (that is where its `code` is),
      # but SPLIT after it, so the tag itself stays inside the region.
      { at: after, node: { t: "code", kind: "block_end", line: l, col: c, output: false, code: src } }
    end

    # `(line, col)` advanced over `prefix`, counting the way a text editor
    # does: a newline moves to the next line and resets the column to 1.
    def advance_pos(line, col, prefix)
      newlines = prefix.count("\n")
      return [line, col + prefix.length] if newlines.zero?
      [line + newlines, prefix.length - prefix.rindex("\n")]
    end

    # `[[name, value-or-nil], ...]` in source order, names lowercased (HTML
    # attribute names are case-insensitive), values verbatim.
    #
    # Two stated limits, both of them "report less rather than report wrong":
    #
    # 1. A value is NOT entity-decoded, so
    #    `data-react-props="{&quot;a&quot;:1}"` reads as non-JSON and the root
    #    is reported `dynamic`. The alternative is a half-decoder that gets a
    #    prop wrong.
    # 2. An element whose OWN start tag is split by an ERB tag
    #    (`<div data-controller="reveal" <%= extra %>>`, or a
    #    `data-react-props="<%= @props.to_json %>"`) produces NO node at all:
    #    no run holds a complete start tag, so there is nothing to classify
    #    and nothing to position. Guessing at the half-tag would invent
    #    attributes the page does not have. But silence here is not
    #    acceptable either -- the template would migrate to inert markup with
    #    no finding to answer -- so the BACKSTOP belongs one layer up, and is
    #    the finding pass's job (Stage 4 Task 3): Stage 1's lexical
    #    `template_scan` markers are purely textual (`data-controller=` is
    #    found by `indexOfPos`, not by parsing a tag), so they still see this
    #    element. The comparison must be by NAME and not by COUNT --
    #    `Markers.stimulus_controllers` is an `addUnique` SET of identifiers,
    #    and `component_roots` names technologies, not occurrences: a marker
    #    name that no element node of this template covers (a `stimulus`
    #    node's `name` is the verbatim `data-controller` value, so split it on
    #    whitespace first) is a tag the parser could not reach, and the
    #    finding is raised from the MARKER. Such a finding has no extent, so
    #    it can offer `retain`/`blocked` only -- never `island`/`inline`.
    #    (An INNER tag split the same way needs none of this: it only has to
    #    be COUNTED, and `scan_text_run`'s name-only fallback counts it.)
    def parse_attrs(src)
      return [] if src.nil? || src.empty?
      src.scan(ATTRIBUTE).map { |name, dq, sq, uq| [name.downcase, dq || sq || uq] }
    end

    # The node an opening tag becomes, or nil for the overwhelming majority of
    # tags, which are just markup. One node per tag: a tag carrying two of
    # these markers is pathological, and the first match in this order wins.
    def element_info(name, attrs)
      # First occurrence wins, as an HTML parser resolves a duplicate
      # attribute -- `to_h` would keep the LAST, which is the value the
      # browser ignores.
      at = {}
      attrs.each { |k, v| at[k] = v unless at.key?(k) }
      if (identifiers = at["data-controller"])
        # Verbatim: `data-controller="reveal modal"` is two identifiers, and
        # splitting it belongs in the one reader that binds them.
        return { kind: "stimulus", name: identifiers, value: name,
                 attrs: attrs.select { |k, _| STIMULUS_ATTR.match?(k) }.map { |k, v| [k, v.to_s] } }
      end
      if name == "turbo-frame"
        frame = []
        frame << ["src", at["src"].to_s] if at.key?("src")
        frame << ["loading", at["loading"].to_s] if at.key?("loading")
        # Turbo requires an `id`; without one there is nothing for the island
        # to render into and nothing to name the finding after.
        return { kind: "turbo_frame", name: at["id"], value: "turbo-frame", attrs: frame, dynamic: at["id"].nil? }.compact
      end
      if (component = at["data-react-class"])
        props = json_props(at["data-react-props"])
        return props ? { kind: "component_root", name: component, attrs: props }
                     : { kind: "component_root", name: component, dynamic: true }
      end
      return { kind: "vue_root", name: at["data-vue-component"] } if at["data-vue-component"]

      nil
    end

    # `data-react-props`' JSON as typed triples, or nil when this stage cannot
    # carry it: absent, unparseable, not an object, or holding a nested value.
    # Nil is not a loss -- it is what `dynamic: true` reports, and the target's
    # `:props` literal is typechecked, so a prop this stage cannot spell is a
    # question for the operator rather than a guess.
    def json_props(raw)
      return nil if raw.nil?
      parsed =
        begin
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
      return nil unless parsed.is_a?(Hash)
      parsed.map do |k, v|
        type = json_value_type(v)
        return nil if type.nil?
        [k.to_s, v.nil? ? "" : v.to_s, type]
      end
    end

    def json_value_type(value)
      case value
      when String then "string"
      when Integer, Float then "number"
      when true, false then "boolean"
      when nil then "null"
      end
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
        return classify_turbo_frame(args, opts)
      when "turbo_stream_from"
        # The stream's own name, so the finding can say WHICH stream is not
        # carried. Without it every one of them read "turbo-stream ``".
        return { kind: "turbo_stream", name: literal(args.first) }.compact
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
        # The argument SOURCES, not their values -- there are none until
        # request time. A port re-expresses them (`post` -> `rec.id`), which
        # it cannot do without knowing what was written.
        return { kind: "route_helper_dynamic", name: stem, args: args.map { |a| safe_slice(a) } }
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
      # `{ post: post }` is not a literal hash, so this render is `dynamic` --
      # but it is still PORTABLE: the pairs say which template local the
      # partial is handed, which is the one thing a data island has to rename
      # (`post` -> the record it is iterating). Without them the port had to
      # guess the partial's parameter names.
      locals = local_pairs(opts["locals"])
      dynamic = lambda do |name|
        info = { kind: "render_dynamic", name: name }
        locals ? info.merge(attrs: locals) : info
      end
      # `render @post` and friends: the TARGET is runtime state, which is
      # exactly what render_dynamic says -- so no state_or here, an `ivar`
      # node would lose the fact that this is a partial at all.
      return dynamic.call(safe_slice(args.first)) if target.nil?
      lit = literal(target)
      return dynamic.call(safe_slice(target)) if lit.nil?
      return dynamic.call(lit) if opts["collection"] || opts["object"] || opts["layout"]
      if opts["locals"]
        pairs = literal_pairs(opts["locals"])
        return dynamic.call(lit) if pairs.nil?
        return { kind: "render_partial_locals", name: lit, attrs: pairs }
      end
      { kind: "render_partial", name: lit }
    end

    # `turbo_frame_tag "latest", src: posts_path, loading: :lazy do … end`.
    #
    # The `src:` is what makes a frame an island rather than inert markup, and
    # a route helper is how Rails templates spell one -- so it is resolved to
    # a route STEM plus its literal arguments (`value`/`args`, the same shape
    # `route_helper` uses). Anything else in `src:` leaves the node `dynamic`:
    # the island fetches a URL, and a URL this run cannot build is not a
    # choice it can offer.
    #
    # A route-helper `src:` never reaches `attrs` to begin with -- it is a
    # CallNode, and `literal_attrs` keeps only options it could read a VALUE
    # for -- so there is nothing to remove here. (An explicit reject stood
    # here and was dead code: the one mutant this file's tests could not kill.
    # A LITERAL `src: "/posts"` does survive into `attrs`, and stays there on
    # purpose: it is `dynamic` for want of a route stem, and the string is
    # still the only description of the frame's target anyone downstream has.)
    def classify_turbo_frame(args, opts)
      id = literal(args.first)
      info = { kind: "turbo_frame", name: id }
      dynamic = id.nil?
      if (src = opts["src"])
        if src.is_a?(Prism::CallNode) && src.receiver.nil? && src.name.to_s.end_with?("_path", "_url") &&
           all_literal?(positional(src.arguments))
          info[:value] = src.name.to_s.sub(/_(path|url)\z/, "")
          info[:args] = literal_args(positional(src.arguments))
        else
          dynamic = true
        end
      end
      info.merge(attrs: literal_attrs(opts), dynamic: dynamic).compact
    end

    # The TARGET is examined before the text, not after. `link_to post.title,
    # post_path(post)` is dynamic because of its text, but the route it points
    # at is perfectly well known -- and reporting it as `link_to` named no
    # route at all, so the finding read "route helper `link_to` has
    # non-literal arguments" and a port had nothing to rebuild the href from.
    #
    # `value` is the link TEXT's source and `args` the target's argument
    # sources: between them a port can re-express the whole control, which is
    # the difference between a question and an answerable one.
    def classify_link(args, opts)
      text, target = args[0], args[1]
      text_lit = literal(text)
      if target.is_a?(Prism::CallNode) && target.receiver.nil? && target.name.to_s.end_with?("_path", "_url")
        stem = target.name.to_s.sub(/_(path|url)\z/, "")
        targs = positional(target.arguments)
        if text_lit && all_literal?(targs) && all_literal_opts?(opts)
          return { kind: "link_to", name: stem, args: [text_lit] + literal_args(targs), attrs: literal_attrs(opts) }
        end
        # Same reasoning as classify_render: the route is the finding, and
        # route_helper_dynamic already says its argument is runtime state.
        return { kind: "route_helper_dynamic", name: stem, value: safe_slice(text), args: targs.map { |a| safe_slice(a) } }
      end
      if text_lit
        return { kind: "link_to", name: nil, args: [text_lit, literal(target)], attrs: literal_attrs(opts) } if literal(target) && all_literal_opts?(opts)
      end
      { kind: "route_helper_dynamic", name: "link_to", value: safe_slice(text), args: [] }
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
      # TYPED pairs here, and only here: a React prop's type is part of it.
      # `points: 3` has to reach the target as `.points = 3`, not `"3"` -- the
      # island's `Props` interface is typechecked, and a number arriving as a
      # string fails the build with an error about the generated file rather
      # than about the template that caused it.
      pairs = typed_pairs(props)
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
    def all_literal_opts?(opts) = flatten_opts(opts).all? { |_, v| v.is_a?(String) || literal(v) || literal_pairs(v) }
    def literal_args(nodes) = nodes.map { |n| literal(n) }

    def literal_attrs(opts)
      flatten_opts(opts).map { |k, v| [k, v.is_a?(String) ? v : (literal(v) || (literal_pairs(v) ? "{...}" : nil))] }.select { |_, v| v }
    end

    # The option keys whose nested hash Rails' tag helpers spell out as
    # prefixed attributes (ActionView's `TAG_PREFIXES`).
    TAG_PREFIXES = %w[aria data].freeze

    # `[[key, node-or-String], ...]`: the helper's options with every
    # `data:`/`aria:` hash of scalar literals flattened the way Rails renders
    # it -- `data: { turbo_method: :delete }` is `data-turbo-method="delete"`
    # (`tag_options`: the key dasherised, a nil value skipped, a String/Symbol
    # value as is and any other scalar JSON-encoded, so `true` is "true").
    #
    # Reporting that hash as one `data` key holding the `{...}` sentinel was
    # a silent loss on every Rails 7 / Turbo template: `findings.mutationVerb`
    # reads `data-turbo-method` and `convert.confirmText` reads
    # `data-turbo-confirm`, and neither can read a sentinel -- so
    # `link_to "Sign out", logout_path, data: { turbo_method: :delete }`
    # raised no finding and converted to a GET link carrying `data="{...}"`.
    # The flattening happens here, once, so both readers see the attributes
    # Rails would have rendered.
    #
    # `button_to`'s `form: { data: … }` puts the same attributes on the form
    # the button builds, which Turbo consults for a confirmation exactly as
    # it consults the button, so that inner hash lands on the control too;
    # whatever else `form:` carried keeps the sentinel it always had.
    #
    # Only a hash of scalar literals is flattened. A value Rails would
    # JSON-encode (`data: { params: { a: 1 } }`) or evaluate at request time
    # is left exactly as written, and `literal_pairs` says of it what it
    # always said: not literal.
    # ActiveSupport's `blank?` for the only thing a key can be here: a String,
    # which `literal` has already made of a symbol/string/integer key. Spelled
    # out rather than required, because this sidecar deliberately runs on
    # Prism alone -- no Rails in the operator's toolchain -- and `strip` is not
    # the same predicate (ActiveSupport's is `/\A[[:space:]]*\z/`, which is
    # what a non-breaking space would answer differently to).
    def blank_key?(k) = k.nil? || k.match?(/\A[[:space:]]*\z/)

    # ActionView 8.1.3.1 `tag_option` runs the finished attribute NAME through
    # `ERB::Util.xml_name_escape` before writing it, so a key XML forbids in a
    # name comes out with every offending character rewritten to `_`:
    # `data: { "with space" => "v" }` renders `data-with_space="v"`. Reporting
    # the raw `data-with space` was not one attribute at all -- an HTML parser
    # reads `data-with` plus a nameless `space="v"` -- and the converter wrote
    # that pair straight into the target template.
    #
    # The character sets are the XML 1.0 `NameStartChar`/`NameChar` productions
    # ActiveSupport spells out, transcribed rather than required: this sidecar
    # deliberately runs on Prism alone, with no Rails in the operator's
    # toolchain, so `ERB::Util` is not available to call.
    XML_NAME_START_SET =
      "@:A-Z_a-z\u{C0}-\u{D6}\u{D8}-\u{F6}\u{F8}-\u{2FF}\u{370}-\u{37D}\u{37F}-\u{1FFF}" \
      "\u{200C}-\u{200D}\u{2070}-\u{218F}\u{2C00}-\u{2FEF}\u{3001}-\u{D7FF}\u{F900}-\u{FDCF}" \
      "\u{FDF0}-\u{FFFD}\u{10000}-\u{EFFFF}"
    XML_NAME_START_RE = /[^#{XML_NAME_START_SET}]/
    XML_NAME_FOLLOWING_RE = /[^#{XML_NAME_START_SET}\-.0-9\u{B7}\u{0300}-\u{036F}\u{203F}-\u{2040}]/
    XML_NAME_REPLACEMENT = "_"

    # The first character obeys the stricter production (no digit, no `-`, no
    # `.`) and the rest the looser one, exactly as `xml_name_escape` splits
    # them. Every name this is called with already starts with `data-`/`aria-`,
    # so the strict half never fires in practice -- it is transcribed anyway so
    # the function is the one ActionView has, not a subset of it that a future
    # caller would have to re-derive.
    def xml_name_escape(name)
      name = name.to_s
      return "" if blank_key?(name)
      first = name[0].gsub(XML_NAME_START_RE, XML_NAME_REPLACEMENT)
      return first if name.size == 1
      first + name[1..].gsub(XML_NAME_FOLLOWING_RE, XML_NAME_REPLACEMENT)
    end

    def flatten_opts(opts)
      opts.flat_map do |k, v|
        # ActionView 8.1.3.1 `tag_options` opens with `next if key.blank?`, so
        # Rails renders NOTHING for a blank option key -- and it cannot render
        # anything else: an attribute with no name is not markup. Reporting it
        # made the node stream disagree with the page Rails serves, and the
        # converter faithfully emitted `="3"` into a target template.
        next [] if blank_key?(k)

        if TAG_PREFIXES.include?(k)
          prefixed_pairs(k, v) || [[k, v]]
        elsif k == "form"
          form_pairs(v) || [[k, v]]
        else
          [[k, v]]
        end
      end
    end

    # `[["data-turbo-method", "delete"], ...]` for a hash of scalar literals;
    # nil when the node is not one.
    def prefixed_pairs(prefix, node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      node.elements.filter_map do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        return nil if k.nil?
        # `next if k.blank? || v.nil?` is the whole of ActionView 8.1.3.1's
        # filter inside the `data:`/`aria:` arms, and both halves belong here.
        # `data: { "" => 1 }` rendered as `data-="1"`, an attribute Rails
        # never writes.
        next nil if blank_key?(k.to_s)
        # Before `literal`, which reports a nil as "" -- Rails writes no
        # attribute at all for a nil value.
        next nil if e.value.is_a?(Prism::NilNode)
        v = literal(e.value)
        return nil if v.nil?
        [xml_name_escape("#{prefix}-#{k.to_s.tr('_', '-')}"), v]
      end
    end

    # `button_to`'s `form:` hash: its `data:`/`aria:` entries as prefixed
    # pairs, then one `["form", "{...}"]` for whatever else it carried. nil
    # when anything in it is not a literal, so the caller leaves the node as
    # it was.
    def form_pairs(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      out = []
      rest = 0
      node.elements.each do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)&.to_s
        return nil if k.nil?
        if TAG_PREFIXES.include?(k)
          pairs = prefixed_pairs(k, e.value)
          return nil if pairs.nil?
          out.concat(pairs)
        else
          return nil if literal(e.value).nil?
          rest += 1
        end
      end
      out << ["form", "{...}"] if rest > 0
      out
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

    # `literal_pairs` plus the Prism node CLASS as a type name -- the same
    # pairs, with the one fact JSON has and a Ruby literal's rendered text
    # does not: whether `3` was a number or the string "3". Used only by
    # `classify_component`, because it is the only reader whose output is
    # typechecked; every other `attrs` consumer wants the rendered attribute.
    def typed_pairs(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      node.elements.map do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        v = literal(e.value)
        type = ruby_value_type(e.value)
        return nil if k.nil? || v.nil? || type.nil?
        [k.to_s, v, type]
      end
    end

    # A Symbol is a `string`: Rails serialises `on: :yes` into the React props
    # JSON as `"yes"`, and there is no other honest mapping for it.
    def ruby_value_type(node)
      case node
      when Prism::StringNode, Prism::SymbolNode, Prism::InterpolatedStringNode then "string"
      when Prism::IntegerNode, Prism::FloatNode then "number"
      when Prism::TrueNode, Prism::FalseNode then "boolean"
      when Prism::NilNode then "null"
      end
    end

    # `[[key, <source>], ...]` for a hash whose every value is a bare template
    # local; nil otherwise (including for an empty hash, which names nothing).
    # `bare` matters: `{ post: post.first }` is a call the port cannot rename
    # by substituting one identifier, and reporting it as if it could would
    # produce a body that reads a field off the wrong thing.
    def local_pairs(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      pairs = node.elements.map do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        return nil if k.nil? || !bare_local?(e.value)
        [k.to_s, safe_slice(e.value)]
      end
      pairs.empty? ? nil : pairs
    end

    # A template local reaches Prism as a LocalVariableReadNode only when the
    # compiled program assigns it somewhere (a block parameter); an ordinary
    # `post` handed in by the render site is a bare-identifier call instead.
    def bare_local?(node)
      case node
      when Prism::LocalVariableReadNode then true
      when Prism::CallNode then node.receiver.nil? && node.arguments.nil? && node.block.nil? && node.variable_call?
      else false
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
