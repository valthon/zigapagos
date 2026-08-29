# An ERB scanner with Erubi's grammar and trim rules. Rails does not use
# stdlib ERB: ActionView compiles templates with Erubi (trim: true, escape:
# true), so `<%==` is raw output and a code-only tag alone on its line is
# trimmed with its indentation. This is Erubi::Engine#initialize's scan
# loop, ported to emit TOKENS instead of Ruby source -- vendored the same
# way inflect.rb vendors ActiveSupport's inflection rules, so the migration
# adapter sees the same tokens Rails does without depending on the gem.
#
# Never evaluates anything. Templates under migration are untrusted input.
module RailsErb
  # Erubi's own regexp, verbatim.
  TAG = /<%(={1,2}|-|\#|%)?(.*?)([-=])?%>([ \t]*\r?\n)?/m

  # Returns an Array of tokens in source order:
  #   { type: :text, text:, line: }
  #   { type: :code, indicator: ""|"="|"=="|"#"|"-", code:, line:, col: }
  # `<%#` comments emit no token. Their :line/:col (and every later
  # token's) come from true source positions, not from padding, so no
  # newlines need to be synthesized to keep them honest. In the untrimmed
  # case only the comment's surrounding lspace/rspace whitespace survives
  # into the text stream -- exactly as in Erubi's own rendered output.
  def self.scan(src)
    tokens = []
    pos = 0
    is_bol = true
    pending_text = +""
    pending_line = 1

    flush = lambda do
      unless pending_text.empty?
        tokens << { type: :text, text: pending_text, line: pending_line }
        pending_text = +""
      end
    end
    add_text = lambda do |s, at_pos|
      next if s.nil? || s.empty?
      pending_line = line_of(src, at_pos) if pending_text.empty?
      pending_text << s
    end

    src.scan(TAG) do
      m = Regexp.last_match
      indicator, code, tailch, rspace = m[1], m[2], m[3], m[4]
      text_start = pos
      text = src[pos, m.begin(0) - pos]
      tag_pos = m.begin(0)
      pos = m.end(0)
      # rspace (the swallowed trailing newline) sits at the END of the
      # match; its own :line is the line it was ON, not the line after --
      # so any add_text of `rspace` must be positioned at the start of
      # rspace (rspace_pos), never at m.end(0), which is already past it.
      rspace_pos = pos - (rspace ? rspace.length : 0)
      ch = indicator ? indicator[0] : nil

      lspace = nil
      if ch != "="
        if text.empty?
          lspace = "" if is_bol
        elsif text[-1] == "\n"
          lspace = ""
        else
          rindex = text.rindex("\n")
          if rindex
            s = text[(rindex + 1)..]
            if /\A[ \t]*\z/.match?(s)
              lspace = s
              text = text[0..rindex]
            end
          elsif is_bol && /\A[ \t]*\z/.match?(text)
            lspace = text
            text = ""
          end
        end
      end
      is_bol = !rspace.nil?

      add_text.call(text, text_start)
      case ch
      when "="
        rspace = nil if tailch && !tailch.empty?
        add_text.call(lspace, tag_pos)
        flush.call
        tokens << { type: :code, indicator: indicator, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
        add_text.call(rspace, rspace_pos)
      when "#"
        # Erubi pads the *generated Ruby source* with "\n" * n so
        # backtraces still point at the right line -- but that's
        # add_code, never add_text, so none of it reaches the render
        # buffer. A trimmed comment (lspace && rspace) is swallowed
        # whole, same as a trimmed code tag: nothing is emitted.
        # Otherwise only its own surrounding lspace/rspace text (if any)
        # survives -- never a synthesized "\n" for the comment's body.
        unless lspace && rspace
          add_text.call(lspace, tag_pos)
          add_text.call(rspace, rspace_pos)
        end
      when "%"
        add_text.call("#{lspace}<%#{code}#{tailch}%>#{rspace}", tag_pos)
      when nil, "-"
        if lspace && rspace
          flush.call
          tokens << { type: :code, indicator: indicator.to_s, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
          # Erubi keeps the swallowed newline INSIDE the generated code so
          # line numbers stay true; a token stream has no such slot, and
          # the next text token's own :line is computed from its position,
          # so nothing needs re-adding here.
        else
          add_text.call(lspace, tag_pos)
          flush.call
          tokens << { type: :code, indicator: indicator.to_s, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
          add_text.call(rspace, rspace_pos)
        end
      end
    end
    rest = pos.zero? ? src : src[pos..]
    add_text.call(rest, pos)
    flush.call
    tokens
  end

  def self.line_of(src, pos)
    src[0, pos].count("\n") + 1
  end

  def self.col_of(src, pos)
    last_nl = src.rindex("\n", pos - 1) if pos > 0
    last_nl ? pos - last_nl : pos + 1
  end
end
