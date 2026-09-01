# The Rails static-AST sidecar's request loop: a persistent process that
# reads one JSON request per line on stdin and writes one JSON response per
# line on stdout, mirroring runtime/sidecar/render.ts's protocol shape so the
# Zig client side (src/islands/sidecar.zig) is the same code talking to a
# second process.
#
# static_ast mode exists for Rails apps that cannot boot -- missing gems,
# broken initializers, wrong Ruby version -- so malformed/unreadable/
# unparsable input is the EXPECTED input class here, not an edge case. Every
# failure mode below answers with a structured `{"ok":false,...}` line and
# keeps serving: a sidecar that dies on one bad request takes the whole
# migrate run down with it, since one process serves every request in the
# run.
#
# stdout carries the protocol and nothing else. Diagnostics go to stderr;
# a stray `puts`/`warn`/`p` on stdout would desynchronize every response
# after it, because the client reads stdout one line per request.
#
# Unlike render.ts's MAX_LINE_CHARS guard against an unterminated line
# growing its buffer to OOM, this loop has no line-length cap: `$stdin.gets`
# will buffer an arbitrarily long line before returning it. That is a
# deliberate, op-specific call, not a blanket exemption -- it holds for
# `routes` and `controllers` because both send a filesystem path, not an
# inline payload, so a request line is bounded by path length, not by the
# size of the app under migration. `templates` is the exception: it DOES
# send inline data (a path list), so it is the one op that could make this
# loop buffer an unbounded line on a malformed request -- that is exactly
# what `MAX_TEMPLATE_PATHS` below (checked before any file is read) bounds.
require "json"
require_relative "routes"
require_relative "controllers"
require_relative "templates"
require_relative "i18n"

module RailsAnalyze
  # RailsRoutes.parse already rescues StandardError internally (routes.rb's
  # own defense in depth), but Task 3 was bitten by a recursive `concern`
  # raising SystemStackError -- not a StandardError, so a `rescue
  # StandardError` at any layer lets it right through. This loop is the
  # process boundary: rescuing plain `Exception` here (rather than
  # `StandardError`) is deliberate, not sloppy -- the loop's only job is to
  # keep answering requests, and answering `{"ok":false}` for one is strictly
  # better than losing the sidecar (and every request still queued behind
  # it) to an exception class nobody enumerated in advance. This is the one
  # place in the codebase that should catch that broadly, precisely because
  # it is the outermost boundary of a persistent process.
  # Stage 4's manifest wants `discovery.ruby: {available, version}` next to
  # the recovered route/action graphs. `version_check.rb` already knows how
  # to answer that question, but it is a SEPARATE one-shot script (Stage 2's
  # toolchain-bootstrap check) -- spawning it here would mean a second Ruby
  # process, on top of the one already running this very handler, just to
  # ask a question this process can answer about itself via `RUBY_VERSION`.
  # That second spawn could also disagree with this one (a `PATH`/`rbenv`
  # shim resolving differently between two spawns is not hypothetical), so
  # this handler answers from its own interpreter instead. `available` is
  # always `true` here: reaching this line means a Ruby process is, by
  # definition, running and answering requests -- the `false` case belongs
  # entirely to the Zig client, which sets it when Ruby (or the sidecar)
  # never got a chance to run in the first place.
  #
  # Stamped on BOTH `handle_routes`'s and `handle_controllers`'s responses
  # (Stage 4's task-2-fixes.md item 1): each op spawns its own, separate
  # Ruby process (`routes.zig`/`controllers.zig`'s module docs), so each is
  # independently the ONLY evidence that op's own interpreter ran. Stamping
  # `routes` alone meant an app with `app/controllers/` but no
  # `config/routes.rb` published `discovery.ruby.available: false` even
  # though the `controllers` op's sidecar answered successfully in the same
  # run -- Ruby was demonstrably available, just not asked about by the one
  # op this field happened to read. The Zig side (`rails.zig`'s
  # `combineRuby`) ORs the two ops' own answers together rather than one op
  # silently speaking for both.
  RUBY_INFO = { available: true, version: RUBY_VERSION }.freeze

  def self.handle_routes(req)
    root = req["root"]
    # Contract: the client sends an absolute path (the brief's example
    # payload is `/abs/path/to/app`). This handler does not enforce that --
    # a relative root is joined as-is and resolved against this process's
    # cwd, which is almost certainly not what the caller intended -- so the
    # Zig client (Task 5) is responsible for always sending an absolute
    # path rather than this script guessing or normalizing one.
    if !root.is_a?(String) || root.empty?
      return { ok: false, error: "routes: \"root\" must be a non-empty string", ruby: RUBY_INFO }
    end

    routes_path = File.join(root, "config/routes.rb")
    source =
      begin
        File.read(routes_path)
      rescue Errno::ENOENT, Errno::EISDIR
        return { ok: false, error: "no config/routes.rb at #{routes_path}", ruby: RUBY_INFO }
      rescue SystemCallError, IOError => e
        return { ok: false, error: "could not read #{routes_path}: #{e.class}: #{e.message}", ruby: RUBY_INFO }
      end

    # `path:` is the location `.parse` bakes into every unresolved entry's
    # `detail` -- the literal relative path, NOT `routes_path` (absolute:
    # `File.join(root, ...)`). Passing the absolute path here used to mean
    # the SAME app, analyzed at two different checkout directories, produced
    # two different report byte sequences: a determinism violation the
    # spec's Determinism section forbids, and one Stage 4's manifest drift
    # gate cannot tolerate (fix round B / B1). `config/routes.rb` is always
    # at this one fixed location relative to `root`, so the relative path is
    # a literal, not a computed one.
    result = RailsRoutes.parse(source, path: "config/routes.rb")
    { ok: true, routes: result[:routes], unresolved: result[:unresolved], ruby: RUBY_INFO }
  end

  # Walks every `app/controllers/**/*.rb` file under the request's `root`
  # and answers one flattened `actions` array plus one flattened
  # `unresolved` array (each entry carries the offending file's path
  # separately, in its own `path:` key -- see the note below on relative
  # paths).
  #
  # `Dir.glob` against a nonexistent `app/controllers` simply returns `[]`
  # -- no special-casing needed to answer `{"actions":[],"unresolved":[]}`
  # structurally for that case, which is exactly the "answer structurally;
  # do not crash" contract the brief asks for. (The Zig client separately
  # decides -- BEFORE it ever sends this request -- whether an absent
  # `app/controllers/` warrants its own `RAILS_CONTROLLERS_MISSING`
  # blocker, the same way `routes.zig` short-circuits on a missing
  # `config/routes.rb`; this handler's job is only to answer honestly about
  # whatever `root` it is actually given.)
  #
  # A single file's UNREADABLE (could not even be opened -- permissions, a
  # symlink race) is degraded to one `RAILS_CONTROLLER_UNREADABLE` entry for
  # that file rather than failing the whole batch, the same "one bad file
  # must not take down the request" argument `controllers.rb`'s own module
  # doc makes for its per-file `SystemStackError` rescue. This is a
  # DIFFERENT code from `RAILS_CONTROLLER_PARSE_ERROR` (fix round B / B2):
  # a file this handler never managed to READ has told this adapter nothing
  # about its Ruby syntax, so reusing the parse-error code sent a human
  # looking for a syntax error in a file whose real problem is permissions
  # -- the identical read/parse distinction `RAILS_TEMPLATE_UNREADABLE`
  # already draws for templates, now drawn here too.
  #
  # Every `unresolved` entry -- from this handler's own read-failure branch
  # and from `RailsControllers.parse`'s two failure branches -- carries the
  # file's path RELATIVE TO `root`, never the absolute glob result: passing
  # an absolute path here used to mean the SAME app, analyzed at two
  # different checkout directories, produced two different report byte
  # sequences (fix round B / B1). It also names the FILE (not the
  # `app/controllers` directory every finding shares) so the blocker's
  # `path` field -- not just its `detail` -- says which file is at fault.
  def self.handle_controllers(req)
    root = req["root"]
    if !root.is_a?(String) || root.empty?
      return { ok: false, error: "controllers: \"root\" must be a non-empty string", ruby: RUBY_INFO }
    end
    root = File.expand_path(root)

    controllers_root = File.join(root, "app/controllers")
    controllers_root_real =
      begin
        File.realpath(controllers_root)
      rescue SystemCallError
        controllers_root
      end
    actions = []
    layouts = []
    before_actions = []
    skip_before_actions = []
    # Resolving a superclass NAME to a controller key needs to know which
    # keys this walk actually saw, so the edges cannot be emitted inside the
    # file loop -- they are collected here and resolved after it (fix round
    # 2, N1).
    pending_parents = []
    controller_keys = []
    unresolved = []

    Dir.glob(File.join(controllers_root, "**", "*.rb")).sort.each do |file|
      rel_file = file.delete_prefix("#{root}/")
      resolved =
        begin
          File.realpath(file)
        rescue SystemCallError, IOError
          nil
        end
      if resolved && resolved != controllers_root_real && !resolved.start_with?("#{controllers_root_real}#{File::SEPARATOR}")
        unresolved << {
          code: "RAILS_CONTROLLER_UNREADABLE",
          path: rel_file,
          detail: "controller resolves outside root",
          line: 1,
        }
        next
      end
      read_path = resolved || file
      source =
        begin
          # Read the path that was actually checked. Reading through `file`
          # again would let a symlink target change between realpath and read.
          File.read(read_path)
        rescue SystemCallError, IOError => e
          # `e.message` is Ruby's own Errno formatting, generated from
          # whatever path `File.read` was actually given -- the ABSOLUTE
          # `file`, since reading from disk needs a real path. That means
          # `e.message` bakes the absolute path in on its own, independent
          # of the `path:`/`detail:` fix above; `gsub` is what keeps THIS
          # code path deterministic too (fix round B / B1 note: the review's
          # own repro called this "the unreadable-file variant is worse: it
          # prints the absolute path twice").
          unresolved << {
            code: "RAILS_CONTROLLER_UNREADABLE",
            path: rel_file,
            detail: "#{e.class}: #{e.message.gsub(read_path, rel_file).gsub(file, rel_file)}",
            line: 1,
          }
          next
        end

      result = RailsControllers.parse(source, path: rel_file)
      unresolved.concat(result[:unresolved])

      # The key is computed unconditionally now (moved above the
      # `actions.empty?` guard below): a controller that declares `layout`
      # but has no public actions of its own (e.g. an all-`private` base
      # controller meant to be subclassed) must still report its layout --
      # only the per-action loop has nothing to iterate in that case.
      controller_key = controller_path_key(file, controllers_root)

      if (lay = result[:layout])
        layouts << {
          controller: controller_key,
          value: lay[:value],
          disabled: lay[:disabled] == true,
          dynamic: lay[:dynamic] == true,
          line: lay[:line],
        }
      end

      # #167 Stage 3: the class-level filters ride their own flattened array,
      # keyed on the same path-derived `controller_key` the actions use, so
      # the Zig side joins the two on one string. Emitted here for the same
      # reason `layouts` is -- ABOVE the `actions.empty?` guard below: a base
      # controller with a `before_action` and no public actions of its own
      # still guards every subclass action, and dropping its filters because
      # it has no actions to iterate would report exactly the pages that
      # subclass it as unguarded.
      #
      # Filters are reported as DECLARED, one entry per declaring controller
      # -- they are not copied down to each subclass here. Attributing an
      # inherited filter to the route that runs it needs the `parents` chain
      # below, and that join lives in `controllers.zig`'s `guardsFor`, next
      # to the data, rather than being pre-expanded into a wire array whose
      # size is the product of the two (fix round 1, I-1).
      #
      # A `dynamic` entry is emitted WITHOUT `name`/`only`/`except` rather
      # than with null placeholders: the Zig decode defaults them, and a
      # `null` name in the JSON would read as "a filter named nothing"
      # instead of "a filter this walk could not read".
      flatten_filters = lambda do |src, into|
        (src || []).each do |f|
          into <<
            if f[:dynamic]
              { controller: controller_key, dynamic: true, line: f[:line] }
            else
              { controller: controller_key, name: f[:name], only: f[:only],
                except: f[:except], line: f[:line] }
            end
        end
      end
      flatten_filters.call(result[:before_actions], before_actions)
      flatten_filters.call(result[:skip_before_actions], skip_before_actions)

      controller_keys << controller_key
      if result[:superclass]
        pending_parents << {
          controller: controller_key,
          superclass: result[:superclass],
          namespaces: result[:lexical_namespaces] || [],
        }
      end

      # `result[:actions]` is empty both for a bare concern module (Task 1's
      # documented "nothing found" case) and for a controller class with no
      # public methods -- either way there is nothing to derive an action
      # entry FOR, so only the per-action loop is skipped, not the layout
      # reported above.
      next if result[:actions].empty?

      result[:actions].each do |name, shape|
        actions << {
          controller: controller_key,
          action: name,
          only_redirect: shape[:only_redirect],
          renders_json: shape[:renders_json],
          # #167 Stage 3: `[]` for an action with no `redirect_to` at all,
          # never absent -- one shape for every entry (`|| []` covers the
          # older `.parse` failure hashes, which carry no actions anyway).
          redirects: shape[:redirects] || [],
          line: shape[:line],
        }
      end
    end

    # One edge per controller whose superclass this walk could both read and
    # resolve -- so `ApplicationController < ActionController::Base`
    # contributes none, and the chain terminates at the framework rather than
    # at an invented `action_controller/base` node.
    parents = pending_parents.filter_map do |pp|
      parent = resolve_parent_key(pp[:superclass], pp[:namespaces], controller_keys)
      { controller: pp[:controller], parent: parent } if parent
    end

    { ok: true, actions: actions, layouts: layouts, before_actions: before_actions,
      skip_before_actions: skip_before_actions, parents: parents,
      unresolved: unresolved, ruby: RUBY_INFO }
  end

  # Ruby's own constant lookup, restricted to what a superclass name can
  # mean (fix round 2, N1).
  #
  # `module Admin; class UsersController < BaseController` resolves
  # `BaseController` to `Admin::BaseController`, because Ruby searches the
  # LEXICAL scope innermost-outward before falling back to the top level.
  # Reading the name as written gave `base` -- a key no file produces -- so
  # the chain snapped exactly where the review found it, on a shape the
  # previous commit message itself cited.
  #
  # Candidates are the enclosing namespaces innermost-outward, then the bare
  # name; the first whose key names a controller THIS WALK ACTUALLY SAW wins.
  # Matching against the observed keys, rather than trusting the innermost
  # candidate, is what keeps `class Admin::X < ApplicationController` pointing
  # at the real top-level `application` instead of an `admin/application` that
  # does not exist.
  #
  # `namespaces` is the `module` nesting, not the class's qualified name --
  # see `controllers.rb`'s `@lexical_namespaces` for why those differ for the
  # compact `class Admin::UsersController` form.
  #
  # When nothing matches, the top-level reading is the answer: the parent may
  # genuinely be a class this walk never saw (a gem's, or one outside
  # `app/controllers/`), and naming it costs nothing -- the Zig-side walk
  # finds no filters under that key and stops. Failure still degrades to
  # under-reporting, never to attributing a foreign controller's filters.
  def self.resolve_parent_key(name, namespaces, controller_keys)
    return nil unless name.is_a?(String)
    candidates = namespaces.length.downto(1).map { |n| (namespaces[0, n] + [name]).join("::") }
    candidates << name
    candidates.each do |candidate|
      key = controller_key_from_class_name(candidate)
      return key if key && controller_keys.include?(key)
    end
    controller_key_from_class_name(name)
  end

  # Rails' own base classes. A controller whose superclass is one of these
  # inherits no app-declared filters, so the chain ENDS there -- emitting an
  # edge to a key no controller file will ever produce would only make the
  # Zig-side walk take an extra hop to discover the same thing.
  FRAMEWORK_BASE_CLASSES = %w[
    ActionController::Base
    ActionController::API
    ActionController::Metal
    ApplicationRecord
    Object
  ].freeze

  # The controller key a superclass NAME denotes -- `ApplicationController` ->
  # `application`, `Admin::BaseController` -> `admin/base` (fix round 1, I-1).
  #
  # Derived from the class name, unavoidably: unlike `controller_path_key`
  # below, there is no file path to read here, because the parent is named
  # only as a constant in the child's source. That makes this edge a
  # CONVENTION-BASED guess in exactly the way `controller_path_key`'s own
  # comment says a class name is -- a reopened or aliased parent, or one whose
  # file does not follow Rails' naming convention, resolves to a key no
  # controller file produced. The cost of a wrong guess is bounded: the chain
  # walk finds no filters under that key and stops, i.e. it under-reports
  # inherited filters rather than attributing someone else's.
  #
  # nil for no superclass, a framework base class, or a name that does not
  # reduce to a usable key.
  def self.controller_key_from_class_name(name)
    return nil unless name.is_a?(String)
    name = name.delete_prefix("::")
    return nil if name.empty? || FRAMEWORK_BASE_CLASSES.include?(name)
    parts = name.split("::").map { |s| underscore(s) }
    return nil if parts.empty? || parts.any?(&:empty?)
    # A last segment of exactly `Controller` leaves nothing behind, so it
    # names no key -- the same answer Rails' own `controller_path` gives it.
    parts[-1] = parts[-1] == "controller" ? "" : parts[-1].sub(/_controller\z/, "")
    return nil if parts.any?(&:empty?)
    parts.join("/")
  end

  # ActiveSupport's `underscore`, minus the parts nothing here needs (no
  # `::`->`/` -- the caller splits first -- and no acronym table). The first
  # gsub is what keeps a run of capitals together: `APIController` ->
  # `api_controller`, not `a_p_i_controller`.
  def self.underscore(segment)
    segment
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .downcase
  end

  # The Rails controller PATH key a route's `controller` field holds --
  # `admin/users` for `app/controllers/admin/users_controller.rb` -- derived
  # from the FILE PATH, never from `RailsControllers.parse`'s `controller:`
  # field (that field is the Ruby CLASS name, e.g. `"Admin::UsersController"`,
  # which cannot express nesting reliably without evaluating the file: a
  # class can be reopened, aliased, or (as `controllers.rb`'s own doc notes)
  # simply not match Rails' directory-based naming convention at all).
  #
  # Only the LAST path segment loses its `_controller` suffix -- an
  # intermediate namespace segment (`admin/` above) is never itself
  # `..._controller`-suffixed by Rails' own convention, so stripping only the
  # last segment is not a partial fix, it is the whole rule.
  def self.controller_path_key(file, controllers_root)
    rel = file.delete_prefix("#{controllers_root}/").sub(/\.rb\z/, "")
    parts = rel.split("/")
    parts[-1] = parts[-1].sub(/_controller\z/, "")
    parts.join("/")
  end

  # A generous bound on one request's path list. Route-reachable templates
  # number in the hundreds on a large app; this cap exists so a malformed
  # request cannot make the sidecar buffer an unbounded line (see the
  # module doc's note on line length).
  MAX_TEMPLATE_PATHS = 5000

  # One response per requested path, in request order, each either a node
  # stream, a parse error with a line, or an unreadable reason. A path that
  # is absolute or escapes `root` after normalization is refused PER ENTRY
  # (`unreadable: "outside root"`) -- the request names files inside the
  # app under migration and nothing else.
  #
  # `RailsI18n.load(root)` runs ONCE per request, not once per template:
  # `queryOnce` (the Zig client) closes stdin after a single request-response
  # round trip, so a second op in the same request would mean a second
  # interpreter spawn just to re-read the same locale files every template
  # in the batch already needs. All templates in one request therefore see
  # one consistent snapshot of the default locale, which also matches how
  # Rails itself loads locale data once per boot rather than per render.
  #
  # `File.expand_path` normalizes `.`/`..` and a leading `/` but does NOT
  # resolve symlinks, so the string-level check below is only the cheap
  # FIRST gate -- it needs no filesystem access and refuses `../` and
  # absolute inputs before any `realpath` call, but a symlink inside the
  # app that POINTS outside `root` would sail straight through it and get
  # read as ordinary template output. Threat model: this sidecar exists
  # specifically to analyse untrusted third-party/community Rails apps
  # during migration, and a careless or malicious one could plant a
  # symlink to, say, `~/.ssh/id_rsa` and have its contents flow straight
  # into the discovery report (fix round 1, #167 Stage 1 review, R11 --
  # probed live against the pre-fix code). So every entry that survives
  # the cheap gate is ALSO resolved with `File.realpath` and re-checked
  # against the resolved root: a symlink that stays inside `root` reads
  # normally (Rails apps legitimately use them -- shared partials,
  # generated code), one that escapes is refused exactly like a literal
  # `../` escape (`unreadable: "outside root"`), and a broken symlink or
  # any other `realpath` failure degrades to `unreadable` too -- never
  # raises past this handler. This is a READ-only defense: the sidecar
  # never writes, so the only concern is disclosing a file the operator
  # did not intend to hand to migration tooling, not the write-side
  # traversal class path-escape checks usually guard against.
  def self.handle_templates(req)
    root = req["root"]
    if !root.is_a?(String) || root.empty?
      return { ok: false, error: "templates: \"root\" must be a non-empty string", ruby: RUBY_INFO }
    end
    paths = req["paths"]
    return { ok: false, error: "templates: \"paths\" must be an array", ruby: RUBY_INFO } unless paths.is_a?(Array)
    return { ok: false, error: "templates: more than #{MAX_TEMPLATE_PATHS} paths", ruby: RUBY_INFO } if paths.length > MAX_TEMPLATE_PATHS

    table = RailsI18n.load(root)
    root_abs = File.expand_path(root)
    root_real =
      begin
        File.realpath(root_abs)
      rescue SystemCallError
        # `root` itself doesn't exist (or isn't reachable) -- fall back to
        # the already-normalized `root_abs`. Every entry below independently
        # runs its OWN `File.realpath(abs)` against this same nonexistent
        # tree and degrades to `unreadable` on its own, so this fallback
        # only keeps the per-entry prefix check well-defined; it masks no
        # traversal.
        root_abs
      end
    templates = paths.map do |rel|
      next { path: rel.to_s, unreadable: "path is not a string" } unless rel.is_a?(String)
      abs = File.expand_path(rel, root_abs)
      next { path: rel, unreadable: "outside root" } unless abs.start_with?("#{root_abs}/")
      real =
        begin
          File.realpath(abs)
        rescue SystemCallError, IOError => e
          # A dangling symlink (or any other reason `abs` can't be
          # resolved -- permissions on an intermediate directory, etc.)
          # degrades exactly like an unreadable file, never raises: this
          # handler has read nothing yet, so there is nothing more
          # dangerous here than the ordinary "file vanished" case
          # `File.read`'s own rescue below already covers.
          next { path: rel, unreadable: "#{e.class}: #{e.message.gsub(abs, rel)}" }
        end
      next { path: rel, unreadable: "outside root" } unless real.start_with?("#{root_real}/")
      source =
        begin
          File.read(real)
        rescue SystemCallError, IOError => e
          # Same absolute-path sanitization as `handle_controllers`'
          # `RAILS_CONTROLLER_UNREADABLE` branch: `e.message` bakes in
          # whatever path `File.read` actually saw (necessarily `real`,
          # since a real read needs a real path), so it is scrubbed back to
          # the relative literal to keep the response directory-independent.
          next { path: rel, unreadable: "#{e.class}: #{e.message.gsub(real, rel)}" }
        end
      res = RailsTemplates.analyze(source, path: rel, i18n: table)
      res[:error] ? { path: rel, error: res[:error], line: res[:line] } : {
        path: rel,
        nodes: res[:nodes],
        parity_h1: res[:parity_h1],
        parity_h1_node: res[:parity_h1_node],
        parity_links: res[:parity_links],
        parity_link_nodes: res[:parity_link_nodes],
      }
    end
    { ok: true, locale: table.locale, templates: templates, i18n_errors: table.errors, ruby: RUBY_INFO }
  end

  # Dispatch one already-parsed request hash to its op. Broad `rescue
  # Exception` (see module comment) is what keeps a bug anywhere downstream
  # -- the parser, the inflector, this dispatch -- from taking the process
  # down instead of just this one response.
  def self.dispatch(req)
    op = req["op"]
    case op
    when "routes"
      handle_routes(req)
    when "controllers"
      handle_controllers(req)
    when "templates"
      handle_templates(req)
    else
      { ok: false, error: "unknown op: #{op.inspect}" }
    end
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Interrupt (Ctrl-C) and SignalException are Exceptions, not
    # StandardErrors, so the broad rescue above would otherwise absorb them
    # too -- answering a normal `{"ok":false}` line and leaving a sidecar
    # that ignores SIGTERM/SIGINT and cannot be torn down by its parent
    # build process. SystemExit must likewise be allowed through, or an
    # explicit `exit` anywhere downstream would be swallowed the same way.
    # `Interrupt < SignalException`, so this one check covers Ctrl-C too --
    # no separate clause needed.
    raise if e.is_a?(SystemExit) || e.is_a?(SignalException)
    { ok: false, error: "#{e.class}: #{e.message}" }
  end

  # One JSON line in, one JSON line out. A malformed request line (invalid
  # JSON, or valid JSON that isn't an object) answers structurally rather
  # than raising out of the caller's read loop.
  def self.handle_line(line)
    req =
      begin
        JSON.parse(line)
      rescue JSON::ParserError => e
        return { ok: false, error: "invalid request line: #{e.message}" }
      end
    unless req.is_a?(Hash)
      return { ok: false, error: "request line must be a JSON object" }
    end
    dispatch(req)
  end

  # Serve NDJSON requests on stdin until it closes. `$stdin.gets` returns nil
  # at EOF, which ends the loop (and the process) the same way
  # render.ts's `for await` loop ends when the Zig parent closes stdin after
  # its last request -- an ordinary, expected shutdown, not a failure.
  def self.run
    while (line = $stdin.gets)
      line = line.strip
      next if line.empty?
      response = handle_line(line)
      $stdout.puts(JSON.generate(response))
      $stdout.flush
    end
  end
end

RailsAnalyze.run if $PROGRAM_NAME == __FILE__
