# Recovers a Rails route table from config/routes.rb by walking a Prism AST.
#
# config/routes.rb is a Ruby *program*, not data: the canonical way to learn
# its routes is to boot Rails and ask ActionDispatch. static_ast mode exists
# for a Rails app that CANNOT boot (missing gems, broken initializers, wrong
# Ruby version), so the file has to be read as text and its route calls
# interpreted syntactically -- never executed. `eval`-ing an untrusted,
# read-only routes.rb from the app under migration would run arbitrary code
# from that app; there is no acceptable version of that shortcut.
#
# The AST walk cannot evaluate everything a real Rails boot could: string
# interpolation, loops, conditionals, engine mounts, and app-defined router
# classes are all outside what static syntax can resolve. Rather than guess
# at those, every route this module cannot vouch for is either skipped
# entirely -- when even the *shape* of what would be generated is unknown
# (a dynamic namespace/path segment, or a loop whose bound may be runtime
# data) -- or emitted with `certain: false` -- when the shape is fully known
# from the source alone and only its *activation* is in doubt (a route
# inside `if`/`unless`, or inside an app-defined router applying an unknown
# prefix). Either way, a coded `unresolved` entry records what was skipped
# or flagged, and why. A fabricated route is worse than a missing one,
# because a migration acts on what this module reports.
require "prism"
require_relative "inflect"

module RailsRoutes
  # Rails route-DSL HTTP verb methods. `options`/`head` are real Rails DSL
  # methods too (not just HTTP methods); including them costs nothing and
  # keeps this list a superset of the brief's core table (get/post/put/
  # patch/delete/match).
  VERBS = %w[get post put patch delete options head].freeze

  ALL_VERBS = %w[GET POST PUT PATCH DELETE].freeze

  # method_name => [http verb, path-kind]. :update expands to both PATCH
  # and PUT (handled as a special case in expand_resources) because Rails
  # itself registers both for the same action.
  RESOURCE_ACTIONS = {
    index: ["GET", :collection],
    create: ["POST", :collection],
    new: ["GET", :new],
    edit: ["GET", :edit],
    show: ["GET", :member],
    update: ["PATCH", :member],
    destroy: ["DELETE", :member],
  }.freeze

  # `path` is the accumulated URL prefix (e.g. "/admin"); `module_` is the
  # accumulated controller-namespace prefix (e.g. "admin"). They diverge
  # under `scope path:`/`scope module:`, which is why they are tracked
  # separately rather than as one string. `as_prefix` is the accumulated
  # `namespace`/`scope as:` route-helper-name prefix (e.g. "admin") -- it
  # tracks the same nesting as module_ but is a SEPARATE string because
  # `scope as:` (unlike `scope module:`) has no path/controller side effect
  # of its own; conflating the two would prefix helper names onto routes
  # that never asked for it.
  Scope = Struct.new(:path, :module_, :as_prefix) do
    def child(path: self.path, module_: self.module_, as_prefix: self.as_prefix)
      Scope.new(path, module_, as_prefix)
    end
  end

  # Carries the enclosing `resources`/`resource` call's identity into a
  # nested block, so `member`/`collection`/`new` and bare nested routes know
  # what resource they belong to without re-deriving it from `sc.path`
  # (which, inside the block, is already suffixed with the parent-id param
  # for the benefit of bare nested routes -- see Walker#resources_call).
  # `name_singular`/`name_plural` are the route-helper stems (`"post"`/
  # `"posts"`) -- distinct from `singular` (which is "was this declared with
  # `resource` or `resources`") because `as:` can override the stem
  # (`resources :articles, as: :stories` keeps `singular` false but makes
  # `name_plural` "stories", not "articles"). When this resource is itself
  # nested inside another (resources_call runs with a non-nil res_ctx), both
  # fields are already fully compounded with every ancestor's singular name
  # (`resources :posts do resources :comments do resources :replies end
  # end` -- replies' own name_singular is "post_comment_reply", matching
  # Rails' Mapper#resource_scope pushing the parent's singular name the same
  # way `namespace`/`scope as:` push theirs) -- every consumer of these two
  # fields (this resource's own actions, member/collection/new, and a bare
  # nested route) reads one already-compounded stem and does no ancestor-
  # walking of its own.
  ResourceCtx = Struct.new(:base, :ctrl, :singular, :name_singular, :name_plural, keyword_init: true)

  def self.parse(source, path:)
    result = Prism.parse(source)
    if result.failure?
      err = result.errors.first
      return {
        routes: [],
        unresolved: [{
          code: "RAILS_ROUTES_PARSE_ERROR",
          detail: "#{path}: #{err&.message || "parse error"}",
          line: err&.location&.start_line || 1,
        }],
      }
    end

    walker = Walker.new
    walker.walk(result.value.statements&.body || [], Scope.new("", "", ""), nil)
    walker.result
  rescue StandardError => e
    # Defense in depth: even a bug in this walker must not raise. The
    # sidecar that calls this is a long-lived process handling many repos
    # in one run; one malformed routes.rb must not kill the whole batch.
    {
      routes: [],
      unresolved: [{
        code: "RAILS_ROUTES_PARSE_ERROR",
        detail: "#{path}: #{e.class}: #{e.message}",
        line: 1,
      }],
    }
  end

  # Holds per-parse mutable state (routes/unresolved/concerns/uncertainty
  # depth). A fresh instance per #parse call -- RailsRoutes.parse is called
  # repeatedly in one long-lived sidecar process, so this state cannot live
  # in module-level globals without leaking between calls.
  class Walker
    def initialize
      @routes = []
      @unresolved = []
      @concerns = {}
      @uncertain = false
      # Names currently being expanded, innermost last -- a "currently
      # visiting" set for cycle detection. Catches both direct
      # (`concern :a do concerns :a end`) and indirect (a -> b -> a)
      # recursion, since it is checked against every name on the way down,
      # not just the immediately enclosing one.
      @concern_stack = []
      # Innermost-last stack of the enclosing member/collection/new block
      # kind(s), so verb_call can tell `member { post :publish }` (->
      # publish_post) apart from `collection { get :recent }` (-> recent_
      # posts) apart from `new { get :preview }` (-> preview_new_post)
      # without member_collection_new_call having to invent a new Scope
      # field just to carry one symbol one level down.
      @res_kind_stack = []
    end

    def result
      { routes: @routes, unresolved: @unresolved }
    end

    def walk(nodes, sc, res_ctx)
      nodes.each { |n| visit(n, sc, res_ctx) }
    end

    private

    # ---- node dispatch ------------------------------------------------

    def visit(node, sc, res_ctx)
      case node
      when Prism::StatementsNode
        walk(node.body, sc, res_ctx)
      when Prism::CallNode
        call(node, sc, res_ctx)
      when Prism::IfNode, Prism::UnlessNode
        # Every branch is real source, not just the first: an if/elsif/else
        # chain routes through IfNode#subsequent (another IfNode per elsif,
        # an ElseNode for the final else); UnlessNode has no elsif and
        # exposes its else via #else_clause instead, NOT #subsequent --
        # unless/else routes were being silently dropped (no route, no
        # unresolved entry) until this walked that branch too. One mark
        # covers the whole chain; walk_conditional_branches does the
        # per-branch recursion without re-marking each elsif.
        mark_unresolved("RAILS_ROUTE_CONDITIONAL", line_of(node),
                         "route(s) inside a conditional")
        with_uncertain { walk_conditional_branches(node, sc, res_ctx) }
      when Prism::CaseNode, Prism::CaseMatchNode
        # case/when (and case/in pattern matching) is morally an if/elsif
        # chain -- each `when`/`in` clause and the else are all real,
        # mutually-exclusive source, so all of them are walked, marked
        # uncertain together under one CONDITIONAL entry. Previously this
        # node type wasn't recognized at all, so its routes vanished with
        # NO trace -- a silent drop is invisible to the consumer even
        # though nothing was fabricated, which defeats the "knows when it
        # cannot" premise as surely as guessing would.
        mark_unresolved("RAILS_ROUTE_CONDITIONAL", line_of(node),
                         "route(s) inside a case/when")
        with_uncertain do
          (node.conditions || []).each { |c| walk(c.statements&.body || [], sc, res_ctx) }
          walk(node.else_clause.statements&.body || [], sc, res_ctx) if node.else_clause
        end
      when Prism::BeginNode
        # Transparent, like constraints/with_options: begin/end wrapping a
        # route block does not gate whether the route exists (only rescue/
        # ensure clauses are conditional on failure, and routes.rb rarely
        # if ever puts route calls there), so this descends at full
        # certainty rather than marking it -- and, same as CaseNode above,
        # not recognizing this node at all was a silent, unmarked drop.
        walk(node.statements&.body || [], sc, res_ctx)
      else
        # Anything else (constants, literals used as bare statements, etc.)
        # is not a route-DSL construct; nothing to descend into.
      end
    end

    # Recurses through an if/elsif/.../else (or unless/else) chain, walking
    # every branch's body. Only the top-level visit() call marks
    # RAILS_ROUTE_CONDITIONAL -- this does not re-mark per elsif/else, so a
    # long chain produces one unresolved entry, not one per branch.
    def walk_conditional_branches(node, sc, res_ctx)
      case node
      when Prism::IfNode
        walk(node.statements&.body || [], sc, res_ctx)
        walk_conditional_branches(node.subsequent, sc, res_ctx) if node.subsequent
      when Prism::UnlessNode
        walk(node.statements&.body || [], sc, res_ctx)
        walk_conditional_branches(node.else_clause, sc, res_ctx) if node.else_clause
      when Prism::ElseNode
        walk(node.statements&.body || [], sc, res_ctx)
      end
    end

    def call(node, sc, res_ctx)
      name = node.name.to_s
      args = node.arguments&.arguments || []
      opts = hash_opts(args)
      pos = positional(args)
      blk = block_body(node)

      case name
      when "draw"
        draw_call(node, blk, sc, res_ctx)
      when "namespace"
        namespace_call(node, pos, opts, blk, sc, res_ctx)
      when "scope"
        scope_call(node, pos, opts, blk, sc, res_ctx)
      when "constraints", "defaults", "with_options", "scope_module"
        # Transparent for path/controller purposes: none of these change
        # the URL prefix or controller namespace in a way this parser can
        # (or needs to) model, so just descend at the current scope.
        walk(blk, sc, res_ctx)
      when "resources", "resource"
        resources_call(node, name == "resource", pos, opts, blk, sc, res_ctx)
      when "member"
        member_collection_new_call(node, :member, blk, sc, res_ctx)
      when "collection"
        member_collection_new_call(node, :collection, blk, sc, res_ctx)
      when "new"
        member_collection_new_call(node, :new, blk, sc, res_ctx)
      when *VERBS, "match"
        verb_call(node, name, args, opts, pos, sc, res_ctx)
      when "root"
        root_call(node, opts, pos, sc, res_ctx)
      when "mount"
        mark_unresolved("RAILS_ROUTE_ENGINE_MOUNT", line_of(node), safe_slice(node))
      when "concern"
        concern_call(pos, blk)
      when "concerns"
        concerns_call(node, pos, sc, res_ctx)
      when "devise_for"
        mark_unresolved("RAILS_ROUTE_GEM_GENERATED", line_of(node),
                         "#{name} (gem-generated routes)")
      when "devise_scope"
        # Unlike devise_for, devise_scope's block holds real, hand-written
        # route calls (`devise_scope :user do get "/x", to: "a#b" end`) --
        # it just scopes them so Devise's failure app resolves inside the
        # block, without changing path/module the way namespace/scope do.
        # Treating it as GEM_GENERATED (as devise_for correctly is) would
        # silently drop routes this parser can actually read; transparent
        # descent is correct here, the same as constraints/with_options.
        walk(blk, sc, res_ctx)
      when "resolve", "direct"
        # Named-helper DSL that does not itself declare a route; ignore.
      else
        if node.block
          # Any block-taking call this parser does not recognize -- most
          # commonly `each`/`map` generating routes programmatically, but
          # this also covers any other unmodeled DSL wrapper. Unlike a
          # conditional (where the same, statically-known routes exist
          # either way and only their *activation* is in doubt), a loop's
          # bound is frequently runtime data (`Model.all.each`), so even
          # the COUNT of routes it produces is unknowable here -- not just
          # whether they apply. Descending and emitting certain:false
          # routes would therefore still be a guess about shape, not just
          # confidence, so this deliberately does not walk the block at
          # all: the unresolved entry is the only trace it leaves.
          mark_unresolved("RAILS_ROUTE_LOOP", line_of(node),
                           "route(s) inside unrecognized block `#{name}`")
        end
        # No block: not a route-DSL call this parser knows, and it cannot
        # produce a route on its own (e.g. a bare local helper call) --
        # nothing to record.
      end
    end

    # ---- individual constructs -----------------------------------------

    def draw_call(node, blk, sc, res_ctx)
      receiver = node.receiver
      if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        # `X.routes.draw` (receiver is a call chain ending in `.routes`) is
        # the genuine Rails route set and must be descended into normally.
        # A BARE CONSTANT receiver -- `ApiRouteSet::V1.draw(self)` -- is an
        # app-defined router applying a path prefix this parser cannot
        # know. Dispatching on the receiver's node type (not the method
        # name "draw") is what keeps these apart; conflating them means
        # emitting routes at a prefix that was never verified.
        mark_unresolved("RAILS_ROUTE_CUSTOM_ROUTER", line_of(node),
                         "custom router `#{safe_slice(receiver)}.draw`")
        with_uncertain { walk(blk, sc, res_ctx) } if node.block
        return
      end

      if node.block
        walk(blk, sc, res_ctx)
        return
      end

      positional_arg = (node.arguments&.arguments || []).find { |a| !hash_like?(a) }
      ref = literal(positional_arg)
      if ref
        mark_unresolved("RAILS_ROUTE_EXTERNAL_FILE", line_of(node),
                         "draw(:#{ref}) references config/routes/#{ref}.rb")
      end
      # `draw` with neither a block nor a literal file reference cannot be
      # resolved at all; nothing to record beyond that (extremely unlikely
      # to occur in real code).
    end

    def namespace_call(node, pos, opts, blk, sc, res_ctx)
      seg = literal(pos[0])
      if seg.nil?
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "namespace name is not a literal")
        return
      end
      if dynamic_option?(opts, "path")
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "namespace path: is not a literal")
        return
      end
      path_seg = opts["path"] ? literal(opts["path"]) : seg
      new_scope = sc.child(
        path: join(sc.path, path_seg),
        module_: sc.module_.empty? ? seg : "#{sc.module_}/#{seg}",
        # `namespace :admin` prefixes route helpers with `admin_` (Rails'
        # Mapper#namespace passes `as: name` through to the enclosing
        # `scope` call) EVEN WHEN `path:`/`module:` are overridden --
        # unlike path_seg/module_, the as_prefix always uses `seg`, the
        # namespace's own name, never path_opt.
        as_prefix: sc.as_prefix.empty? ? seg : "#{sc.as_prefix}_#{seg}",
      )
      walk(blk, new_scope, res_ctx)
    end

    def scope_call(node, pos, opts, blk, sc, res_ctx)
      path_node = opts["path"] || pos[0]
      new_path = sc.path
      if path_node
        seg = literal(path_node)
        if seg.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                           "scope path is not a literal")
          return
        end
        new_path = join(sc.path, seg)
      end

      new_module = sc.module_
      if opts["module"]
        mod = literal(opts["module"])
        if mod.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                           "scope module: is not a literal")
          return
        end
        new_module = sc.module_.empty? ? mod : "#{sc.module_}/#{mod}"
      end

      new_as = sc.as_prefix
      if opts["as"]
        as_lit = literal(opts["as"])
        if as_lit.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node), "scope as: is not a literal")
          return
        end
        new_as = sc.as_prefix.empty? ? as_lit : "#{sc.as_prefix}_#{as_lit}"
      end

      walk(blk, sc.child(path: new_path, module_: new_module, as_prefix: new_as), res_ctx)
    end

    def resources_call(node, singular, pos, opts, blk, sc, res_ctx)
      # only:/except: gate WHICH of the 8 routes are certain to exist, so
      # an unresolvable value here is exactly as dangerous as an
      # unresolvable path:/controller: -- a computed except: that can't be
      # read excludes nothing (fabricating routes the app may not serve),
      # and a computed only: that can't be read matches nothing (silently
      # discarding the whole resource with no trace). Both must fail
      # closed the same way path:/controller: already did.
      # A computed as: must fail closed too, the same as path:/controller:
      # above: falling through would silently derive the un-aliased name
      # (`nm`) for a resource whose author explicitly overrode it, handing
      # a plausible-looking but wrong helper name to a later stage.
      if dynamic_option?(opts, "path") || dynamic_option?(opts, "controller") ||
         dynamic_option?(opts, "as") ||
         dynamic_array_option?(opts, "only") || dynamic_array_option?(opts, "except")
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "#{singular ? "resource" : "resources"} only:/except:/path:/controller:/as: is not a literal")
        return
      end

      only = opts["only"] ? literal_array(opts["only"]).map(&:to_sym) : nil
      except = opts["except"] ? literal_array(opts["except"]).map(&:to_sym) : []
      path_opt = opts["path"] ? literal(opts["path"]) : nil
      ctrl_opt = opts["controller"] ? literal(opts["controller"]) : nil
      # `resources :photos, concerns: :commentable` is sugar for calling
      # `concerns :commentable` inside the resource's own (possibly absent)
      # block -- Rails' Mapper#resources expands it the same way regardless
      # of whether an explicit `do...end` is also given. Uses arr_syms, not
      # the fail-closed literal_array used above for only:/except: -- an
      # unresolvable concern NAME here is the same "skip this one concern"
      # case concerns_call already treats as a non-fatal, uncoded gap (see
      # arr_syms's own doc), not a reason to distrust the rest of the
      # resource the way an unresolvable only:/except: would be.
      concern_names = opts["concerns"] ? arr_syms(opts["concerns"]) : []

      pos.each do |p|
        nm = literal(p)
        if nm.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                           "#{singular ? "resource" : "resources"} name is not a literal")
          next
        end

        base = join(sc.path, path_opt || nm)
        # #176: a SINGULAR `resource` routes to the PLURAL controller.
        # Rails' SingletonResource#controller is `options[:controller] ||
        # plural`, and its `plural` is `name.to_s.pluralize` -- so
        # `resource :session` is SessionsController, served from
        # app/views/sessions/, while its PATH and its route-helper names
        # stay singular (`/session`, `session_path`, `new_session_path`).
        # Deriving "session" here named a controller file no real app has,
        # so every downstream join (the controller's actions, its views,
        # the auth-journey detection that keys on the `sessions`/
        # `registrations` controller names) missed, and the only way to
        # migrate a real Rails auth flow was an explicit `controller:`
        # override the app does not need. `resources` is unaffected: its
        # name is already the plural.
        ctrl = ctrl_opt || (singular ? Inflect.pluralize(nm) : nm)
        ctrl = sc.module_.empty? ? ctrl : "#{sc.module_}/#{ctrl}"

        actions = singular ? %i[new create edit show update destroy] : %i[index create new edit show update destroy]
        actions = actions.select { |a| only.nil? || only.include?(a) } - except

        # `as:` replaces the PLURAL stem outright (`resources :articles, as:
        # :stories` names every route off "stories", not "articles"); the
        # singular stem is then re-derived from that overridden plural, same
        # as Rails does, so `new`/`edit` still agree with the override
        # (`new_story`, not `new_article`). A singular `resource` has no
        # plural of its own -- `sing` IS the (possibly aliased) stem, and
        # `plural` is set equal to it so collection-kind actions (`create`)
        # get the same name as member-kind ones, matching Rails' `resource`
        # (`resource :profile` names every action "profile").
        as_opt = opts["as"] ? literal(opts["as"]) : nil
        plural = singular ? nm : (as_opt || nm)
        sing = singular ? (as_opt || nm) : Inflect.singularize(plural)
        plural = sing if singular

        # A resource nested inside an enclosing resources/resource block
        # compounds its own stem onto the PARENT's -- Rails' Mapper#resource_
        # scope pushes the parent resource's singular name the same way
        # `namespace`/`scope as:` push their own name onto as_prefix (see
        # prefixed_name below), so `resources :posts do resources :comments
        # end` names comments' own actions "post_comments"/"post_comment",
        # not bare "comments"/"comment". The compounding key is always the
        # parent's SINGULAR stem, never its plural, matching Rails: a
        # comment nested under many posts is still named relative to ONE
        # post ("post_comments", never "posts_comments").
        if res_ctx
          plural = "#{res_ctx.name_singular}_#{plural}"
          sing = "#{res_ctx.name_singular}_#{sing}"
        end

        actions.each do |a|
          verb, kind = RESOURCE_ACTIONS[a]
          route_path = resource_action_path(base, kind, singular)
          stem = case kind
                 when :collection then plural
                 when :member then sing
                 when :new then "new_#{sing}"
                 when :edit then "edit_#{sing}"
                 end
          emit(verb, route_path, ctrl, a.to_s, line_of(node), name: prefixed_name(sc, stem))
          emit("PUT", route_path, ctrl, "update", line_of(node), name: prefixed_name(sc, stem)) if a == :update
        end

        next unless blk || !concern_names.empty?

        parent_param = singular ? nil : ":#{Inflect.singularize(nm)}_id"
        inner_path = singular ? base : join(base, parent_param)
        inner_scope = sc.child(path: inner_path)
        inner_ctx = ResourceCtx.new(base: base, ctrl: ctrl, singular: singular,
                                     name_singular: sing, name_plural: plural)
        # A nested `resources`/`resource` establishes its OWN resource
        # identity, so its body must not inherit an ENCLOSING member/
        # collection/new kind (`resources :posts do collection { resources
        # :comments do get :flag end } end` -- the bare `get :flag` nested
        # inside :comments must derive "flag_comment", the ordinary bare-
        # nested-route shape, not "flag_comments" by mistakenly reading the
        # outer :collection off a stack that was never popped for this
        # inner resources call). @res_kind_stack is saved/cleared/restored
        # around this call's own body for exactly that reason -- pushing an
        # extra frame (rather than clearing) would still leak the outer
        # kind to anything that checks "stack non-empty" without also
        # checking whose resource it belongs to.
        saved_res_kind_stack = @res_kind_stack
        @res_kind_stack = []
        begin
          walk(blk, inner_scope, inner_ctx) if blk
          concern_names.each { |cn| expand_concern(cn, inner_scope, inner_ctx, line_of(node)) }
        ensure
          @res_kind_stack = saved_res_kind_stack
        end
      end
    end

    def resource_action_path(base, kind, singular)
      case kind
      when :collection then base
      when :new then join(base, "new")
      when :edit then singular ? join(base, "edit") : join(join(base, ":id"), "edit")
      when :member then singular ? base : join(base, ":id")
      end
    end

    def member_collection_new_call(node, kind, blk, sc, res_ctx)
      # `member`/`collection`/`new` outside a `resources`/`resource` block
      # is invalid Rails DSL (there is nothing for them to scope), so a
      # real routes.rb never reaches this with res_ctx nil; skip silently
      # rather than invent a code for input that isn't a valid construct
      # to begin with -- same rationale as the undefined-concern case in
      # concerns_call.
      return unless res_ctx

      new_path = case kind
                 when :member then res_ctx.singular ? res_ctx.base : join(res_ctx.base, ":id")
                 when :collection then res_ctx.base
                 when :new then join(res_ctx.base, "new")
                 end
      # A fresh ResourceCtx (rather than reusing res_ctx as-is) keeps this
      # symmetric with resources_call's own inner_ctx construction; @res_
      # kind_stack -- not a new Scope field -- is what actually tells
      # verb_call it is inside member/collection/new, since kind is
      # per-block state, not scope state that should keep flowing past this
      # block's `end`.
      inner_ctx = ResourceCtx.new(base: res_ctx.base, ctrl: res_ctx.ctrl, singular: res_ctx.singular,
                                   name_singular: res_ctx.name_singular, name_plural: res_ctx.name_plural)
      @res_kind_stack.push(kind)
      walk(blk, sc.child(path: new_path), inner_ctx)
      @res_kind_stack.pop
    end

    def verb_call(node, name, args, opts, pos, sc, res_ctx)
      rocket = rocket_pair(args)
      # `Mapper#match` (what get/post/.../match all delegate to) accepts
      # MULTIPLE positional paths -- `get "/a", "/b", to: "x#y"` is valid
      # Rails and yields two routes sharing one to:/action:/controller:.
      # `pos[0]` alone silently dropped every path after the first with no
      # unresolved trace. The hashrocket form (`"/a" => "ctrl#action"`) is
      # its own single-path spelling and never co-occurs with bare
      # positional paths, so it only supplies a path when pos is empty.
      # `had_explicit_path` distinguishes "genuinely no path argument at
      # all" (a bare `nil` seg is a legitimate value: the route is just
      # `sc.path`) from "a path argument that failed to resolve" (also a
      # `nil` seg, but one that must not be emitted) -- both would
      # otherwise collapse to the same `seg.nil?` below.
      had_explicit_path = pos.any? || rocket
      path_nodes = pos.empty? ? (rocket ? [rocket.first] : [nil]) : pos
      target_node = opts["to"] || opts["action"] || rocket&.last

      # Resolve every path first, marking (not aborting on) any individual
      # unresolvable one -- a dynamic SECOND path must not silently erase a
      # resolvable FIRST path, the same "don't let one bad element taint an
      # otherwise-recoverable call" principle literal_array already applies
      # to only:/except:/via:.
      segs = path_nodes.map do |path_node|
        next nil unless had_explicit_path
        seg = literal(path_node)
        if seg.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                           "#{name} path is not a literal")
        end
        seg
      end
      # Every explicit path was unresolvable: nothing left to emit (each one
      # already recorded its own unresolved entry above).
      return if had_explicit_path && segs.all?(&:nil?)

      # An explicit to:/action: target that IS PRESENT but cannot be read
      # (`to: redirect("/new")`, `to: SOME_CONST`) must not fall through to
      # `action ||= seg` below -- that would silently substitute the raw
      # path string (or the bare segment) as the action, inventing a
      # plausible-looking controller#action for a route whose real
      # destination is unknown. Only an ABSENT target_node makes seg-as-
      # action a legitimate default, and only when it isn't itself a
      # slash-prefixed path (see the comment at that fallback below).
      # to:/action:/controller: apply uniformly across every path in the
      # call, so an unresolvable one aborts the whole call, not just one
      # path.
      if target_node && literal(target_node).nil?
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "#{name} to:/action: target is not a literal")
        return
      end
      if dynamic_option?(opts, "controller")
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "#{name} controller: is not a literal")
        return
      end
      if dynamic_option?(opts, "as")
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "#{name} as: is not a literal")
        return
      end

      ctrl, target_action = ctrl_action(literal(target_node))
      ctrl ||= opts["controller"] ? literal(opts["controller"]) : nil
      # An explicit "ctrl#action"/controller: target is resolved relative
      # to the enclosing namespace/scope module -- `namespace :admin do get
      # "/x", to: "pages#y" end` routes to Admin::PagesController, exactly
      # as it would if this had been written as `resources :pages`. Only
      # the resources-derived fallback (res_ctx&.ctrl) already carries the
      # module prefix baked in from expansion time, so it must NOT be
      # re-prefixed here.
      ctrl = apply_module(ctrl, sc) if ctrl
      ctrl ||= res_ctx&.ctrl

      verbs =
        if name == "match"
          if opts["via"]
            via = literal_array(opts["via"])
            if via.nil?
              mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                               "match via: is not a literal")
              return
            end
            via.map(&:downcase) == ["all"] ? ALL_VERBS : via.map(&:upcase)
          else
            ["GET"]
          end
        else
          [name.upcase]
        end

      segs.each do |seg|
        next if had_explicit_path && seg.nil? # this one failed to resolve; already marked above

        # `post :publish` (inside member/collection) has no to:/action: at
        # all -- seg IS the action, by DSL convention. That convention only
        # holds when there is genuinely no target (target_node nil,
        # checked above and returned-from otherwise) and seg is a bare
        # relative name, not a full path (`get "/old"` with no target must
        # not silently become action "/old").
        action = target_action
        if action.nil? && target_node.nil? && seg && !seg.start_with?("/")
          action = seg
        end

        route_path = seg ? join(sc.path, seg) : sc.path

        # Mirrors Rails' Mapper#name_for_action precedence: an explicit
        # as: always wins; failing that, a route declared inside member/
        # collection/new gets the Rails-conventional
        # "<seg>_<singular-or-plural>" shape (publish_post, recent_posts,
        # preview_new_post); failing that, a bare route nested directly in
        # a resources block (no member/collection/new wrapper -- see the
        # "bare nested route" test) gets "<singular>_<seg>" -- name FIRST,
        # segment second, per Mapper#name_for_action's :nested scope
        # ([parent_member_name, action]) -- R7 (review, fix round 1) caught
        # that this file had the order backwards ("<seg>_<singular>",
        # "stats_post" instead of "post_stats"), built on an earlier, wrong
        # reading of the plan; and with none of that, a literal path derives
        # its own name the way Rails would from an ungrouped `get "/about"`.
        route_name =
          if opts["as"]
            as_lit = literal(opts["as"])
            as_lit.nil? ? nil : prefixed_name(sc, as_lit)
          elsif res_ctx && !@res_kind_stack.empty? && seg && !seg.start_with?("/")
            case @res_kind_stack.last
            when :member then prefixed_name(sc, "#{seg}_#{res_ctx.name_singular}")
            when :collection then prefixed_name(sc, "#{seg}_#{res_ctx.name_plural}")
            when :new then prefixed_name(sc, "#{seg}_new_#{res_ctx.name_singular}")
            end
          elsif res_ctx && seg && !seg.start_with?("/")
            # bare route inside a resources block (`resources :posts do get :stats end`)
            prefixed_name(sc, "#{res_ctx.name_singular}_#{seg}")
          else
            prefixed_name(sc, derived_name_from_path(seg))
          end

        verbs.each { |v| emit(v, route_path, ctrl, action, line_of(node), name: route_name) }
      end
    end

    def root_call(node, opts, pos, sc, res_ctx)
      target = opts["to"] || pos[0]
      # See verb_call: a target that IS PRESENT but unresolvable
      # (`root to: redirect("/x")`) must not fall through to the "index"
      # default below -- that would invent an action for a route whose
      # real destination this parser cannot read.
      if target && literal(target).nil?
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "root to: target is not a literal")
        return
      end
      if dynamic_option?(opts, "controller") || dynamic_option?(opts, "action")
        mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node),
                         "root controller:/action: is not a literal")
        return
      end

      ctrl, action = ctrl_action(literal(target))
      ctrl ||= opts["controller"] ? literal(opts["controller"]) : nil
      action ||= opts["action"] ? literal(opts["action"]) : nil
      # See verb_call: an explicit target is resolved relative to the
      # enclosing namespace/scope module; the res_ctx fallback is already
      # module-prefixed from resource expansion and must not be re-prefixed.
      ctrl = apply_module(ctrl, sc) if ctrl
      ctrl ||= res_ctx&.ctrl
      path = sc.path.empty? ? "/" : sc.path
      emit("GET", path, ctrl, action || "index", line_of(node), name: prefixed_name(sc, "root"))
    end

    def concern_call(pos, blk)
      nm = literal(pos[0])
      @concerns[nm] = blk if nm && blk
    end

    def concerns_call(node, pos, sc, res_ctx)
      # `concerns :commentable, :image_attachable` (the multi-name form
      # documented in the Rails routing guide) previously only expanded
      # pos[0] -- every name after the first was silently dropped, with no
      # unresolved entry, exactly the "knows when it cannot" premise this
      # module exists to uphold. flat_map over every positional arg (each
      # of which may itself be a literal array, e.g. `concerns %i[a b]`)
      # fixes both the plain multi-arg and the array-arg spelling.
      names = pos.flat_map { |p| arr_syms(p) }
      names.each { |cn| expand_concern(cn, sc, res_ctx, line_of(node)) }
    end

    # Shared by concerns_call (the `concerns :a, :b` DSL form) and
    # resources_call (the `resources :x, concerns: :a` option form) --
    # Rails expands both identically, so the cycle-guarded walk lives in
    # one place rather than two.
    #
    # An undefined concern name is not in the coded taxonomy (it is a
    # broken routes.rb, not an unresolvable-but-valid construct); skip
    # silently rather than fabricate a code for it.
    def expand_concern(cn, sc, res_ctx, line)
      stored = @concerns[cn]
      return unless stored
      # `concern :a do concerns :a end` (direct) or a -> b -> a
      # (indirect): re-walking a concern already on the expansion stack
      # would recurse without ever terminating. Prism.parse succeeded --
      # this is a live, unbounded Ruby call stack, not a parse error, so
      # nothing under `rescue StandardError` in RailsRoutes.parse would
      # catch it (SystemStackError < Exception, not StandardError). Six
      # lines of routes.rb would otherwise take down the whole batch in
      # a long-lived sidecar process.
      #
      # Coded RAILS_ROUTE_CONCERN_CYCLE, not RAILS_ROUTE_LOOP: LOOP means a
      # RUNTIME-BOUNDED loop (`Model.all.each` -- the count depends on data
      # unknown until boot), which a consumer reading it would go looking
      # for dynamically generated routes to explain. A concern cycle is
      # STRUCTURALLY broken source -- it can never resolve regardless of
      # runtime data -- so it gets its own code rather than reusing one
      # that implies the wrong kind of unresolvability.
      if @concern_stack.include?(cn)
        mark_unresolved("RAILS_ROUTE_CONCERN_CYCLE", line,
                         "concern :#{cn} recursively expands itself (#{(@concern_stack + [cn]).join(" -> ")})")
        return
      end
      @concern_stack.push(cn)
      begin
        walk(stored, sc, res_ctx)
      ensure
        @concern_stack.pop
      end
    end

    # ---- literal / argument extraction ---------------------------------

    def literal(node)
      case node
      when Prism::SymbolNode, Prism::StringNode then node.unescaped
      else nil # InterpolatedStringNode, local vars, method calls, etc: unresolvable statically
      end
    end

    def hash_like?(node)
      node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)
    end

    def positional(args)
      args.reject { |a| hash_like?(a) }
    end

    def hash_opts(args)
      out = {}
      args.each do |a|
        next unless hash_like?(a)
        a.elements.each do |e|
          next unless e.is_a?(Prism::AssocNode)
          next unless e.key.is_a?(Prism::SymbolNode)
          out[e.key.unescaped] = e.value
        end
      end
      out
    end

    # The `"path" => "controller#action"` hashrocket form parses into the
    # same KeywordHashNode as `to:`/`path:` options, distinguished only by
    # the key node's type (a string-like key, not a symbol). Returns
    # [key_node, value_node] so the caller can literal-check the key node
    # itself (an interpolated key must still trip RAILS_ROUTE_DYNAMIC_PATH,
    # not be silently ignored).
    def rocket_pair(args)
      args.each do |a|
        next unless hash_like?(a)
        a.elements.each do |e|
          next unless e.is_a?(Prism::AssocNode)
          next if e.key.is_a?(Prism::SymbolNode)
          return [e.key, e.value]
        end
      end
      nil
    end

    def ctrl_action(target)
      return [nil, nil] unless target
      target.include?("#") ? target.split("#", 2) : [nil, target]
    end

    # DEPRECATED for anything that decides route certainty:
    # `filter_map` silently drops a non-literal element instead of
    # signaling that the array couldn't be fully resolved, and a
    # non-array/non-literal `node` (a bare identifier, a method call)
    # returns [] -- indistinguishable from "resolved to an empty list".
    # Both of those turned a dynamic only:/except:/via: into a silent
    # fabrication (empty except: excludes nothing; empty only: matches
    # nothing) rather than an unresolved entry. Kept only for
    # concerns_call, where an unresolvable name just means "skip this
    # one concern" -- not "assert something about every route in scope".
    # Anything that gates route emission must use literal_array instead.
    def arr_syms(node)
      case node
      when Prism::ArrayNode then node.elements.filter_map { |e| literal(e) }
      when Prism::SymbolNode, Prism::StringNode then [literal(node)]
      else []
      end
    end

    # Like literal(), but for an array-shaped option (only:/except:/via:).
    # Returns nil -- "unresolvable, do not guess" -- both when `node`
    # itself isn't a literal array/symbol/string, AND when it's an array
    # containing even one non-literal element (a single computed entry
    # taints the whole option, since e.g. `except: [:destroy, SOME_CONST]`
    # gives no way to know what SOME_CONST removes).
    def literal_array(node)
      case node
      when Prism::ArrayNode
        result = []
        node.elements.each do |e|
          v = literal(e)
          return nil if v.nil?
          result << v
        end
        result
      when Prism::SymbolNode, Prism::StringNode
        [literal(node)]
      else
        nil
      end
    end

    # True when `opts[key]` is present but not a literal we can resolve
    # (as opposed to absent, which is a no-op for the caller).
    def dynamic_option?(opts, key)
      opts[key] && literal(opts[key]).nil?
    end

    # Same as dynamic_option?, but for an array-shaped option -- see
    # literal_array.
    def dynamic_array_option?(opts, key)
      opts[key] && literal_array(opts[key]).nil?
    end

    def apply_module(ctrl, sc)
      return ctrl if sc.module_.empty?
      "#{sc.module_}/#{ctrl}"
    end

    def block_body(node)
      blk = node.block
      return [] unless blk.is_a?(Prism::BlockNode)
      case blk.body
      when Prism::StatementsNode then blk.body.body
      when Prism::BeginNode then blk.body.statements&.body || []
      when nil then []
      else [blk.body]
      end
    end

    # ---- path building ---------------------------------------------------

    def join(a, b)
      return a if b.nil? || b.to_s.empty?
      bs = b.to_s
      bs = "/#{bs}" unless bs.start_with?("/")
      "#{a}#{bs}".gsub(%r{/+}, "/")
    end

    # ---- emission --------------------------------------------------------

    def emit(verb, path, ctrl, action, line, name: nil)
      p = path.nil? || path.empty? ? "/" : path
      p = p == "/" ? "/" : p.chomp("/")
      p = "/" if p.empty?
      @routes << {
        verb: verb,
        path: p,
        controller: ctrl,
        action: action,
        # Task 1 (#167 Stage 1): the Rails route-helper name (`posts` for
        # `posts_path`), derived by the same rules Rails' Mapper applies.
        # nil under @uncertain on purpose: a helper resolving to a route
        # this parser is not vouching for must become a finding
        # (RAILS_ROUTE_HELPER_UNKNOWN), not a confident URL.
        name: @uncertain ? nil : name,
        line: line,
        certain: !@uncertain,
      }
    end

    # Joins the scope's as_prefix and a route's own name stem with `_`,
    # returning nil when the stem is nil (a route Rails itself would not
    # name, e.g. a bare path with a dynamic segment and no as:).
    def prefixed_name(sc, stem)
      return nil if stem.nil? || stem.empty?
      sc.as_prefix.empty? ? stem : "#{sc.as_prefix}_#{stem}"
    end

    # Rails' Mapper#name_for_action derives a helper name from a literal
    # path when no as: is given: segments joined by `_`, with any dynamic
    # (`:id`) or glob (`*path`) segment making the route nameless.
    def derived_name_from_path(seg)
      return nil if seg.nil?
      parts = seg.split("/").reject(&:empty?)
      return nil if parts.empty?
      return nil if parts.any? { |s| s.start_with?(":", "*") || s.include?("(") }
      parts.join("_").tr("-", "_")
    end

    def mark_unresolved(code, line, detail)
      @unresolved << { code: code, detail: detail, line: line }
    end

    def with_uncertain
      prev = @uncertain
      @uncertain = true
      yield
    ensure
      @uncertain = prev
    end

    def line_of(node)
      node.location.start_line
    rescue StandardError
      1
    end

    def safe_slice(node)
      node.slice
    rescue StandardError
      "?"
    end
  end
  private_constant :Walker
end
