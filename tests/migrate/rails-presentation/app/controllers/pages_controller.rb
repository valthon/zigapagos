# Declares `layout "marketing"` -- a literal value, so every action here
# resolves that exact layout, no fallback (pinned via /about in
# rails-presentation.sh: about_layout == app/views/layouts/marketing.html.erb).
class PagesController < ApplicationController
  layout "marketing"

  # Clean page: about.html.erb resolves `t(".heading")` successfully and
  # renders only static markup otherwise, so it must raise ZERO findings
  # (pinned: about_count == 0) even though every OTHER view in this fixture
  # raises at least one.
  def about
  end

  # help.html.erb is the one template that packs HELPER_UNKNOWN,
  # RAW_OUTPUT, and I18N_UNRESOLVED into a single line.
  def help
  end

  # #167 Stage 2: nothing but a `redirect_to` in the body -- classifier rule
  # 3. There is no app/views/pages/old.html.erb and there must not be one:
  # the point of this action is that the route never renders anything, so the
  # conversion has nothing to write and the handoff says `redirect`.
  def old
    redirect_to about_path
  end

  # broken.html.erb has an unclosed `<% if x %>` -- exercises
  # RAILS_TEMPLATE_PARSE_ERROR (self-review coverage, not in the core pins).
  def broken
  end

  # links.html.erb calls `ghost_path`, a route helper naming no route this
  # run recovered -- exercises RAILS_ROUTE_HELPER_UNKNOWN (self-review
  # coverage, not in the core pins).
  def links
  end

  # linked.html.erb is replaced with a symlink pointing outside the app tree
  # by rails-presentation.sh -- the templates op refuses it, the transitive
  # scan reads it, and RAILS_TEMPLATE_UNSCANNED is what says so (R15).
  def linked
  end

  def widgets
  end

  def live
  end

  def stream
  end
end
