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
# deliberate, op-specific call, not a blanket exemption -- it holds because
# `routes` sends a filesystem path, not an inline payload, so a request line
# is bounded by path length, not by the size of the app under migration. A
# future op that sends inline data (a file's contents, a diff) would NOT
# inherit this exemption and should add its own cap.
require "json"
require_relative "routes"

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
  def self.handle_routes(req)
    root = req["root"]
    # Contract: the client sends an absolute path (the brief's example
    # payload is `/abs/path/to/app`). This handler does not enforce that --
    # a relative root is joined as-is and resolved against this process's
    # cwd, which is almost certainly not what the caller intended -- so the
    # Zig client (Task 5) is responsible for always sending an absolute
    # path rather than this script guessing or normalizing one.
    if !root.is_a?(String) || root.empty?
      return { ok: false, error: "routes: \"root\" must be a non-empty string" }
    end

    routes_path = File.join(root, "config/routes.rb")
    source =
      begin
        File.read(routes_path)
      rescue Errno::ENOENT, Errno::EISDIR
        return { ok: false, error: "no config/routes.rb at #{routes_path}" }
      rescue SystemCallError, IOError => e
        return { ok: false, error: "could not read #{routes_path}: #{e.class}: #{e.message}" }
      end

    result = RailsRoutes.parse(source, path: routes_path)
    { ok: true, routes: result[:routes], unresolved: result[:unresolved] }
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
