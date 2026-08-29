# runtime/sidecar/rails/test/erb_test.rb
require_relative "../erb"

# Expectations follow Erubi (the engine Rails actually uses, trim: true).
# To cross-check against the real gem: `gem install erubi` and run
#   ruby -rerubi -e 'puts Erubi::Engine.new(File.read(ARGV[0]), trim: true).src' FILE
# -- every text run below must appear as a `_buf << '...'` literal there
# with the same whitespace, and every code token as the same statement.
$failures = 0
def check(label, src, expected)
  got = RailsErb.scan(src).map { |t| t.reject { |k, _| k == :col } }
  return if got == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

check "text only", "<h1>Hi</h1>\n", [{ type: :text, text: "<h1>Hi</h1>\n", line: 1 }]

check "output tag keeps surrounding text and newline",
      "<p><%= @x %></p>\n",
      [{ type: :text, text: "<p>", line: 1 },
       { type: :code, indicator: "=", code: " @x ", line: 1 },
       { type: :text, text: "</p>\n", line: 1 }]

check "raw output tag is its own indicator",
      "<%== raw_html %>",
      [{ type: :code, indicator: "==", code: " raw_html ", line: 1 }]

check "a code-only tag alone on its line is trimmed with its indentation and newline",
      "<ul>\n  <% items.each do |i| %>\n  <li><%= i %></li>\n  <% end %>\n</ul>\n",
      [{ type: :text, text: "<ul>\n", line: 1 },
       { type: :code, indicator: "", code: " items.each do |i| ", line: 2 },
       { type: :text, text: "  <li>", line: 3 },
       { type: :code, indicator: "=", code: " i ", line: 3 },
       { type: :text, text: "</li>\n", line: 3 },
       { type: :code, indicator: "", code: " end ", line: 4 },
       { type: :text, text: "</ul>\n", line: 5 }]

check "a code tag with text before it on the same line is NOT trimmed",
      "<b><% x = 1 %>\n",
      [{ type: :text, text: "<b>", line: 1 },
       { type: :code, indicator: "", code: " x = 1 ", line: 1 },
       { type: :text, text: "\n", line: 1 }]

check "-%> drops the trailing newline on an output tag",
      "<%= a -%>\nb",
      [{ type: :code, indicator: "=", code: " a ", line: 1 },
       { type: :text, text: "b", line: 2 }]

# A trimmed comment (alone on its line) swallows its own newline just like
# a trimmed code tag: nothing reaches the render buffer for it. Erubi pads
# the *generated Ruby source* with blank lines for backtrace accuracy, but
# that's source padding (add_code), never appended to _buf (add_text) --
# confirmed via `Erubi::Engine.new("<%# note %>\n<%= a %>", trim: true).src`,
# which shows no `_buf << "\n"` for the comment at all, only code-line
# padding. A token stream has no source-padding slot and needs none: line
# numbers already come from true source positions.
check "a trimmed comment emits no token at all -- not even a text token",
      "<%# note %>\n<%= a %>",
      [{ type: :code, indicator: "=", code: " a ", line: 2 }]

# An untrimmed comment (text before it on the same line) contributes only
# its own lspace/rspace surround to the buffer -- never synthetic padding
# for the newlines inside/after the tag. Verified via
# `Erubi::Engine.new("<b><%# c %>\nX", trim: true).src`, whose buffer is
# '<b>' + '\n' + 'X' (one newline, from rspace, merged into one text run
# since the comment itself emits no token to break it).
check "an untrimmed single-line comment contributes only its rspace, not padding",
      "<b><%# c %>\nX",
      [{ type: :text, text: "<b>\nX", line: 1 }]

# A multi-line comment body contributes NO newlines to the buffer at all
# when untrimmed with no rspace -- Erubi's buffer for
# `Erubi::Engine.new("<b><%# foo\nbar %>X", trim: true).src` is
# '<b>' + 'X' ("<b>X", zero newlines): the comment's internal "\n" never
# reaches the render output, only the generated-source padding does.
check "a multi-line comment's internal newlines never reach the text buffer",
      "<b><%# foo\nbar %>X",
      [{ type: :text, text: "<b>X", line: 1 }]

check "<%% is literal text",
      "<%% not code %>",
      [{ type: :text, text: "<% not code %>", line: 1 }]

check "col is the 1-based column of the tag" , "", []
got = RailsErb.scan("ab <%= c %>")
unless got[1] && got[1][:col] == 4
  warn "FAIL col: #{got.inspect}"; $failures += 1
end

check "an unterminated tag is text (Erubi does the same)",
      "<p><% oops\n",
      [{ type: :text, text: "<p><% oops\n", line: 1 }]

abort "#{$failures} erb failure(s)" if $failures > 0
puts "PASS: erb_test.rb"
