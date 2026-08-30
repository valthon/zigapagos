# Reads controller-action SHAPE from a Prism AST: which public methods are
# actions, and for each, whether its body is purely a redirect and whether it
# ever renders JSON. Classification (Stage 3) uses these three structural
# facts to steer a route toward build-time content, an island, backend
# responsibility, or a redirect that needs no page at all.
#
# #167 Stage 3 adds the two facts the BACKEND BOUNDARY needs on top of that
# steering, both about what the action does that a static page cannot:
#
# - `redirects` (per action) -- WHERE each `redirect_to` goes, as a route
#   helper stem plus literal arguments. `only_redirect` said only THAT the
#   body was a redirect, which is why the handoff's `redirects[].to` has been
#   null since Stage 2 and why a form island had nowhere to send the browser
#   after a successful mutation.
# - `before_actions` (per class) -- the class-level filters, with their
#   only:/except: scope. A static page cannot enforce a Rails auth filter, so
#   a page route whose controller runs one has to raise a question rather
#   than ship silently public.
#
# Filters INHERIT, so the two facts above are not enough on their own: the
# commonest Rails auth idiom by far puts `before_action :authenticate_user!`
# on `ApplicationController` and never repeats it, and a walk that reported
# only each class's own filters would attribute that one to `application`
# while every route names `posts`, `pages`, ... -- i.e. would report every
# guarded page as unguarded, which is the exact failure the field exists to
# prevent (fix round 1, I-1). So `.parse` also reports:
#
# - `superclass` -- the SOURCE TEXT of the class's superclass
#   (`"ApplicationController"`), or nil when there is none or it is not a
#   plain constant. Turning that into a controller key is `analyze.rb`'s job
#   (it owns what a controller key looks like); walking the resulting chain
#   is `controllers.zig`'s `guardsFor`.
# - `skip_before_actions` -- `skip_before_action` declarations, same entry
#   shape as `before_actions`. A subclass that skips an inherited filter is
#   how Rails apps make a login page reachable, and without them the chain
#   walk would raise a question about every one of those.
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
        # A file this walk rejected has told it nothing about the class-level
        # filters either; an empty list is the honest answer, and keeps every
        # caller on ONE shape instead of a nil check per failure branch.
        before_actions: [],
        skip_before_actions: [],
        superclass: nil,
        lexical_namespaces: [],
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
    # the walker ever runs.
    #
    # The guarantee this rescue provides has a PLATFORM LIMIT worth stating
    # plainly, because it was found the hard way. Deep enough nesting
    # exhausts the native C stack inside Prism's parser, and how that
    # surfaces is platform-specific: on Linux it arrives as a catchable
    # SystemStackError, which this clause degrades to one unresolved entry;
    # on the macOS arm64 CI runner the same 20,000-deep input aborts the
    # interpreter outright with a native SIGILL (`Illegal instruction: 4`),
    # killing the process before ANY Ruby rescue runs -- including this one,
    # and including analyze.rb's process-boundary `rescue Exception`. So a
    # sufficiently pathological controller file can still take the sidecar
    # down on some platforms, and no rescue can prevent it.
    #
    # No depth pre-check guards against that, deliberately: it would mean a
    # new heuristic and a magic number defending against an input that does
    # not occur in real controllers, and the honest limit is cheaper to
    # state than to police. `controllers_test.rb` therefore RAISES
    # SystemStackError directly rather than provoking it with deep source,
    # so it tests this clause on every platform instead of only where the
    # error happens to be catchable. That is a different vector from routes.rb's
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
      before_actions: [],
      skip_before_actions: [],
      superclass: nil,
      lexical_namespaces: [],
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
      @layout = nil
      # Class-level `before_action` declarations of the ONE chosen class, in
      # source order (#167 Stage 3). Per class, not per action: Rails runs
      # them for every action the only:/except: scope covers, and deciding
      # WHICH actions that is belongs to the consumer that knows the route
      # (`controllers.zig`'s `guards`), not to this walk.
      @before_actions = []
      # `skip_before_action` declarations, same entry shape. Kept in their
      # OWN list rather than as a flag on `@before_actions`: a consumer that
      # iterated one merged array without checking the flag would read a skip
      # as a guard, i.e. would invent a guard where the app removed one.
      @skip_before_actions = []
      # Source text of the chosen class's superclass, for the inheritance
      # chain (fix round 1, I-1). Not a controller key -- see #superclass_name.
      @superclass = nil
      # The `module` nesting the chosen class was written inside, outermost
      # first, ONE ENTRY PER `module` KEYWORD (fix rounds 2 N1 and 3 NEW-1).
      # This mirrors Ruby's `Module.nesting`, which is what it consults to
      # resolve the superclass name, and it is deliberately neither of the
      # two things it is easy to confuse it with:
      #
      # - NOT the class's own qualified name. `class Admin::UsersController`
      #   (the compact CLASS form) opens no module, so a bare
      #   `BaseController` in it resolves at top level, while the same text
      #   inside `module Admin` tries `Admin::BaseController` first.
      # - NOT a `::`-split of the accumulated path. `module Admin::Deep` (the
      #   compact MODULE form) has nesting `[Admin::Deep]`; `Admin` is NOT in
      #   scope, so `BaseController` there is the top-level one even when
      #   `Admin::BaseController` exists. Splitting on `::` invented an
      #   `Admin` scope Ruby never searches.
      @lexical_namespaces = []
    end

    def result
      { controller: @controller, actions: @actions, layout: @layout,
        before_actions: @before_actions, skip_before_actions: @skip_before_actions,
        superclass: @superclass, lexical_namespaces: @lexical_namespaces,
        unresolved: [] }
    end

    # Collects every top-level class (recursing through `module` wrappers
    # for namespacing, never merging across classes), then commits to
    # exactly one of them: the first whose qualified name ends in
    # "Controller", or -- if none do -- the first class in the file. Only
    # that one class's body is walked for actions.
    def walk(nodes, namespaces = [])
      collect_classes(nodes, namespaces)
      chosen = @classes.find { |c| c[:name].end_with?("Controller") } || @classes.first
      return unless chosen
      @controller = chosen[:name]
      @superclass = superclass_name(chosen[:node])
      @lexical_namespaces = chosen[:namespaces]
      walk_class_body(chosen[:node])
    end

    private

    # The SOURCE TEXT after `<`, when it is a plain constant
    # (`ApplicationController`, `Admin::BaseController`). `slice` for the
    # identical reason `collect_classes` uses it on `constant_path`: `#name`
    # holds only the last segment, silently dropping a namespace.
    #
    # nil for a class with no superclass, and for a superclass this walk
    # cannot read as a name at all -- `class C < Rails.application.config.x`,
    # `class C < base_for(:x)`, an anonymous `Class.new`. nil is the honest
    # answer there, and it costs only that one edge: the chain walk stops,
    # which under-reports inherited filters rather than attributing them to a
    # guessed parent.
    def superclass_name(class_node)
      sc = class_node.superclass
      return nil unless sc.is_a?(Prism::ConstantReadNode) || sc.is_a?(Prism::ConstantPathNode)
      sc.slice
    end

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
    def collect_classes(nodes, namespaces)
      nodes.each do |node|
        case node
        when Prism::ClassNode
          @classes << {
            name: (namespaces + [node.constant_path.slice]).join("::"),
            node: node,
            namespaces: namespaces,
          }
        when Prism::ModuleNode
          # One ENTRY per `module` keyword, never per `::`-separated segment
          # (fix round 3, NEW-1). `module Admin::Deep` is a single scope --
          # Ruby's `Module.nesting` there is `[Admin::Deep]`, not
          # `[Admin::Deep, Admin]` -- so its slice stays one indivisible
          # string. Accumulating a flat `"Admin::Deep::"` PREFIX instead made
          # the compact and the nested spellings produce identical bytes, so
          # nothing downstream could tell a two-level nesting from a
          # one-level compact path at all.
          collect_classes(statements_of(node.body), namespaces + [node.constant_path.slice])
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
          # A `self` receiver on this CALL is not the same distinction a
          # `self.` receiver on a DEF makes (instance vs. class method):
          # `self.layout "x"` is the identical class-level DSL call as the
          # bare `layout "x"` form, just with the receiver spelled out. Any
          # OTHER receiver (`Foo.layout "x"`) is a different method and
          # must stay excluded. `before_action` reads the receiver exactly
          # the same way, and for the same reason.
          bare = n.receiver.nil? || n.receiver.is_a?(Prism::SelfNode)
          record_layout(n) if bare && n.name == :layout
          record_filter(n, @before_actions) if bare && n.name == :before_action
          record_filter(n, @skip_before_actions) if bare && n.name == :skip_before_action
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

    # `layout "x"` is the only static shape. `layout :sym` names a method
    # Rails calls per request; a proc, a non-literal, or a literal carrying
    # only:/except: are all decided at request time -- reported as dynamic
    # so the Zig side can fall back to convention AND raise a finding,
    # instead of guessing which layout wins.
    def record_layout(node)
      line = node.location.start_line
      args = node.arguments&.arguments || []
      first = args.first
      has_opts = args.any? { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
      @layout =
        if first.is_a?(Prism::StringNode) && !has_opts
          { value: first.unescaped, line: line }
        elsif first.is_a?(Prism::FalseNode) && !has_opts
          { value: nil, disabled: true, line: line }
        else
          { dynamic: true, line: line }
        end
    end

    # ---- class-level filters ---------------------------------------------

    # `before_action :sym[, :sym2][, only:/except: ...]` -- one entry per
    # SYMBOL, because Rails registers one filter per symbol and each is
    # independently a name the auth heuristic has to read.
    #
    # Anything this walk cannot reduce to a name is ONE `{dynamic: true}`
    # entry: a bare block, a proc/lambda, a constant, or an only:/except:
    # value that is not a symbol or an array of symbols. Reporting a scope this
    # walk could not read as an EMPTY scope would be the dangerous direction
    # -- an empty `only` means "guards every action" to `guards`, so a
    # misread `only: GUARDED` would claim the filter covers actions it does
    # not, and mark pages open that Rails serves publicly.
    #
    # `after_action`/`around_action` are not collected at all: they run after
    # or around the response, so they cannot gate whether the page is
    # reachable, which is the only question this field is asked.
    #
    # `if:`/`unless:` are deliberately IGNORED rather than degraded to
    # dynamic. They make a filter conditional at request time, so a named
    # entry over-reports -- but a dynamic entry carries no name, the auth
    # heuristic could not see it, and the guarded page would ship silently
    # public. Over-reporting raises a question the operator can answer;
    # under-reporting does not.
    #
    # `before_action(:x) { ... }` registers BOTH in Rails, and the same
    # argument settles it the same way: the SYMBOL is recorded and the block
    # goes unread. Reporting the whole call dynamic instead would throw away
    # the one name the auth heuristic could have seen. The block is then a
    # filter this walk does not know about -- the same gap every `dynamic`
    # entry already has, not a new one.
    # Shared by `before_action` and `skip_before_action` (fix round 1, I-1):
    # the two take identical arguments, and reading them differently would be
    # a bug waiting to happen -- a skip whose scope was parsed by a second,
    # slightly different reader would suppress the wrong actions.
    def record_filter(node, into)
      line = node.location.start_line
      args = node.arguments&.arguments || []
      opts, names = args.partition { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }

      if names.empty? || opts.length > 1 || names.any? { |a| !filter_name_node?(a) }
        into << { dynamic: true, line: line }
        return
      end

      only = filter_scope(opts.first, "only")
      except = filter_scope(opts.first, "except")
      if only == :dynamic || except == :dynamic
        into << { dynamic: true, line: line }
        return
      end

      names.each do |sym|
        into << { name: sym.unescaped, only: only, except: except, line: line }
      end
    end

    # Rails accepts a string wherever it accepts a symbol here
    # (`before_action "require_login"`) and resolves both to the same method,
    # so both are names (fix round 1, I-4). `#unescaped` reads the same on
    # either node.
    def filter_name_node?(node)
      node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end

    # `[]` when the key is absent, the action names when it is a symbol or an
    # array of symbols, `:dynamic` for anything else (see
    # #record_before_action for why "anything else" must not collapse to
    # `[]`).
    def filter_scope(opts, key)
      return [] if opts.nil?
      assoc = opts.elements.find do |e|
        e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == key
      end
      return [] if assoc.nil?
      case (value = assoc.value)
      when Prism::SymbolNode then [value.unescaped]
      when Prism::ArrayNode
        return :dynamic unless value.elements.all? { |e| e.is_a?(Prism::SymbolNode) }
        value.elements.map(&:unescaped)
      else :dynamic
      end
    end

    # ---- per-action analysis --------------------------------------------

    def analyze_action(def_node)
      stmts = statements_of(def_node.body)
      {
        only_redirect: stmts.length == 1 && redirect_to_call?(stmts.first),
        renders_json: any_render_json?(def_node.body),
        redirects: collect_redirects(def_node.body),
        line: def_node.location.start_line,
      }
    end

    # Every `redirect_to` in the body, in source order -- NOT just the
    # top-level one `only_redirect` looks at. A redirect inside an `if` is
    # still where that branch sends the browser, and reproducing it is
    # exactly what a form island replacing the action has to do.
    def collect_redirects(body)
      out = []
      return out unless body
      each_descendant(body) do |n|
        if redirect_to_call?(n)
          out << redirect_target(n)
        elsif back_redirect_call?(n)
          out << { dynamic: true }
        end
      end
      out
    end

    # `redirect_back` (and its Rails 7 spelling `redirect_back_or_to`) send
    # the browser to `HTTP_REFERER`, which is a request-time value no static
    # build can know -- and its `fallback_location:` is only what happens
    # when that value is missing, not where the action goes. So they are
    # `{dynamic: true}`, NOT absent (fix round 1, I-2): an empty `redirects`
    # list means "this action does not redirect", and answering that for an
    # action that plainly does would have a consumer render a page for a
    # route the app never renders one for.
    BACK_REDIRECT_METHODS = %w[redirect_back redirect_back_or_to].freeze

    def back_redirect_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? &&
        BACK_REDIRECT_METHODS.include?(node.name.to_s)
    end

    # `{name: <stem>, args: [<literal>, ...]}` when the target is a route
    # helper call this walk can read whole, `{dynamic: true}` otherwise.
    #
    # `name` is the helper STEM (`root` for `root_path`, `post` for
    # `post_url`) because that is what the Zig side resolves against the
    # route table it recovered from `config/routes.rb`.
    #
    # A bare string (`redirect_to "/about"`) is its own third variant,
    # `{path: "/about"}` (fix round 1, I-3), rather than being folded into
    # either of the other two: it is perfectly literal, so calling it dynamic
    # throws away a target a consumer can use verbatim -- but it names no
    # helper, so putting it in `name` would have consumers resolve it against
    # a route table it was never in. `path` is the string EXACTLY as written,
    # which may be an absolute URL; it is not normalised or validated here.
    #
    # A trailing options hash (`notice:`, `status:`) is dropped before the
    # target is examined -- it is Rails' flash/response plumbing, not part
    # of the URL, and letting it count as a second positional argument would
    # push every ordinary `redirect_to root_path, notice: "..."` into
    # `dynamic`.
    def redirect_target(node)
      args = (node.arguments&.arguments || []).reject do |a|
        a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode)
      end
      return { dynamic: true } unless args.length == 1

      target = args.first
      # An InterpolatedStringNode is deliberately NOT a StringNode here: its
      # value is a request-time one, so it stays dynamic.
      return { path: target.unescaped } if target.is_a?(Prism::StringNode)
      return { dynamic: true } unless target.is_a?(Prism::CallNode) &&
                                      target.receiver.nil? && target.block.nil?

      stem = target.name.to_s[/\A(.+)_(?:path|url)\z/, 1]
      return { dynamic: true } if stem.nil?

      helper_args = (target.arguments&.arguments || []).map { |a| literal_argument(a) }
      return { dynamic: true } if helper_args.any?(&:nil?)
      { name: stem, args: helper_args }
    end

    # The argument forms a route helper can take that this walk can render
    # back as the literal text a URL needs. An integer keeps its source text
    # (`post_path(1)` -> `"1"`) rather than being re-formatted from a parsed
    # value; anything else -- an ivar, a local, a method call, an
    # interpolated string -- is `nil`, i.e. "not literal".
    def literal_argument(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::SymbolNode then node.unescaped
      when Prism::IntegerNode then node.slice
      end
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
