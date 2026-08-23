# Reads controller-action SHAPE from a Prism AST: which public methods are
# actions, and for each, whether its body is purely a redirect and whether it
# ever renders JSON. Classification (Stage 3) uses these three structural
# facts to steer a route toward build-time content, an island, backend
# responsibility, or a redirect that needs no page at all.
#
# A controller under migration is read-only AND untrusted input, exactly like
# config/routes.rb (see routes.rb's header) -- so this walks a Prism AST and
# never evaluates the file. There is no acceptable version of that shortcut.
#
# This is a sibling of routes.rb, not a consumer of it: no require_relative
# to routes.rb. Controllers and routes are independent inputs to the same
# classification step, and coupling the two parsers would make either one
# harder to reason (or fail) about in isolation.
require "prism"

module RailsControllers
  def self.parse(source, path:)
    result = Prism.parse(source)
    if result.failure?
      err = result.errors.first
      return {
        controller: nil,
        actions: {},
        # `path:` (not baked into `detail` -- fix round B / B1) is always
        # the RELATIVE path the caller passed in (`analyze.rb`'s
        # `handle_controllers` -- the only production caller -- computes it
        # relative to `root`; `controllers_test.rb` passes a relative
        # literal directly), so this never re-leaks the caller's absolute
        # path even though this module has no `root` of its own to relate
        # anything to.
        unresolved: [{
          code: "RAILS_CONTROLLER_PARSE_ERROR",
          path: path,
          detail: err&.message || "parse error",
          line: err&.location&.start_line || 1,
        }],
      }
    end

    walker = Walker.new
    walker.walk(result.value.statements&.body || [])
    walker.result
  rescue StandardError, SystemStackError => e
    # Defense in depth, same rationale as routes.rb: this is a sibling
    # module in the same long-lived sidecar process, so a bug in this
    # walker must degrade to one unresolved entry, never take the batch
    # down.
    #
    # SystemStackError is listed explicitly (not covered by `rescue
    # StandardError` -- SystemStackError < Exception, not StandardError)
    # because `Prism.parse` itself can raise it on syntactically VALID but
    # deeply-nested source (e.g. tens of thousands of nested `[`), before
    # the walker ever runs. That is a different vector from routes.rb's
    # SystemStackError hole (unbounded `concern` self-reference, defused
    # there with explicit cycle detection, not a rescue): here there is no
    # expansion step to add cycle detection to, so catching the class by
    # name at this boundary is the fix. Unlike Task 2's process-boundary
    # `rescue Exception` in analyze.rb (which must also catch
    # SignalException so the sidecar stays killable by its parent build),
    # this is a per-file boundary: Task 2's `controllers` op walks MANY
    # files per request, so catching one file's SystemStackError here
    # degrades that ONE file to an unresolved entry instead of failing the
    # whole batch of files the request covers. It deliberately does NOT
    # widen to `rescue Exception` -- SignalException must keep propagating
    # untouched, all the way out to that same process boundary.
    {
      controller: nil,
      actions: {},
      unresolved: [{
        code: "RAILS_CONTROLLER_PARSE_ERROR",
        path: path,
        detail: "#{e.class}: #{e.message}",
        line: 1,
      }],
    }
  end

  # Holds per-parse mutable state. A fresh instance per #parse call --
  # RailsControllers.parse is called repeatedly in one long-lived sidecar
  # process, so this state cannot live in module-level globals.
  class Walker
    def initialize
      @controller = nil
      @actions = {}
      # Every top-level class found during the collect pass, in source
      # order, as {name:, node:}. Actions are recorded from exactly ONE of
      # these (see #walk) -- a file can legitimately hold more than one
      # class (a controller alongside a small prelude, or two namespaced
      # controllers sharing a file), and merging every class's methods
      # into one flat @actions hash under one @controller name is wrong in
      # two ways at once: the reported controller name may not be the
      # class the actions actually came from, AND a same-named action in a
      # later sibling class silently overwrites an earlier, unrelated
      # one's shape -- observed producing a wrongly-`only_redirect: true`
      # result for a plain content action, purely because a same-named
      # `redirect_to`-only action existed in a different class later in
      # the same file. See controllers_test.rb's "two controllers in one
      # file" cases.
      @classes = []
    end

    def result
      { controller: @controller, actions: @actions, unresolved: [] }
    end

    # Collects every top-level class (recursing through `module` wrappers
    # for namespacing, never merging across classes), then commits to
    # exactly one of them: the first whose qualified name ends in
    # "Controller", or -- if none do -- the first class in the file. Only
    # that one class's body is walked for actions.
    def walk(nodes, module_prefix = "")
      collect_classes(nodes, module_prefix)
      chosen = @classes.find { |c| c[:name].end_with?("Controller") } || @classes.first
      return unless chosen
      @controller = chosen[:name]
      walk_class_body(chosen[:node])
    end

    private

    # ---- top-level dispatch --------------------------------------------

    # Only descends into class/module wrappers looking for controller
    # classes; everything else at file scope (requires, constants, bare
    # statements) is not a controller-DSL construct.
    #
    # `constant_path.slice` (not `#name`) is what makes the compact form
    # (`class Admin::PostsController`) read correctly: `#name` only ever
    # holds the LAST segment (`:PostsController`), silently dropping the
    # `Admin::` prefix -- source text via constant_path is the honest
    # answer, not a guess reassembled from parts. The nested-`module`
    # form's prefix is threaded down through `module_prefix` instead, since
    # a ModuleNode's body is a plain statement list with no name attached
    # to the class inside it.
    def collect_classes(nodes, module_prefix)
      nodes.each do |node|
        case node
        when Prism::ClassNode
          @classes << { name: "#{module_prefix}#{node.constant_path.slice}", node: node }
        when Prism::ModuleNode
          collect_classes(statements_of(node.body), "#{module_prefix}#{node.constant_path.slice}::")
        end
      end
    end

    # ---- class body: actions + visibility -------------------------------

    def walk_class_body(class_node)
      visibility = :public
      statements_of(class_node.body).each do |n|
        case n
        when Prism::DefNode
          record_action(n) if visibility == :public && n.receiver.nil?
        when Prism::CallNode
          visibility = handle_visibility_call(n, visibility)
        end
      end
    end

    # `private`/`protected`/`public` with NO arguments switches the running
    # default for every def that follows in this class body (until the next
    # such call). The same names called WITH an argument that is itself a
    # `def` (`private def foo; end`) apply only to that one method and do
    # NOT change the running default -- real Ruby's `Module#private` returns
    # its argument precisely so this inline form composes, and the method
    # named in that inline form was already excluded from -- or, for an
    # inline `public`, included in -- @actions by the branch below, since it
    # is never itself a top-level class-body statement (it is nested inside
    # the CallNode's arguments, which walk_class_body's `case` never
    # descends into).
    def handle_visibility_call(node, visibility)
      name = node.name.to_s
      return visibility unless %w[private protected public].include?(name)
      return visibility if node.receiver

      args = node.arguments&.arguments || []
      if args.empty?
        name == "public" ? :public : :private
      else
        inline_def = args.find { |a| a.is_a?(Prism::DefNode) }
        record_action(inline_def) if inline_def && name == "public" && inline_def.receiver.nil?
        visibility # inline form never changes the running default
      end
    end

    def record_action(def_node)
      @actions[def_node.name.to_s] = analyze_action(def_node)
    end

    # ---- per-action analysis --------------------------------------------

    def analyze_action(def_node)
      stmts = statements_of(def_node.body)
      {
        only_redirect: stmts.length == 1 && redirect_to_call?(stmts.first),
        renders_json: any_render_json?(def_node.body),
        line: def_node.location.start_line,
      }
    end

    # Exactly one statement, and that statement is a bare `redirect_to`
    # call. A redirect alongside other statements is deliberately NOT a
    # pure redirect -- see the module doc and controllers_test.rb.
    def redirect_to_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == "redirect_to"
    end

    # Unlike only_redirect (which looks only at the top-level statement
    # shape), a `render json:` may be nested inside an if/case/begin --
    # still a real, unconditionally-parseable call, just not the method's
    # only statement. So this walks every descendant of the body, not just
    # the top level.
    def any_render_json?(body)
      return false unless body
      found = false
      each_descendant(body) do |n|
        found = true if render_json_call?(n)
      end
      found
    end

    def render_json_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil? && node.name.to_s == "render"
      args = node.arguments&.arguments || []
      args.any? do |a|
        next false unless a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode)
        a.elements.any? do |e|
          e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == "json"
        end
      end
    end

    def each_descendant(node, &blk)
      return unless node.respond_to?(:compact_child_nodes)
      blk.call(node)
      node.compact_child_nodes.each { |c| each_descendant(c, &blk) }
    end

    # ---- shared helpers ---------------------------------------------------

    def statements_of(body)
      case body
      when Prism::StatementsNode then body.body
      when nil then []
      else [body]
      end
    end
  end
  private_constant :Walker
end
