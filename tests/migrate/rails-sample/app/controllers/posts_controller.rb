class PostsController < ApplicationController
  def index; @posts = Post.all; end

  # Classifier rule 3 fixture: a pure redirect, nothing else in the body.
  def old
    redirect_to posts_path
  end

  # Classifier rule 2 fixture: renders JSON directly, never a view.
  def stats
    render json: { count: Post.count }
  end

  # A1 fixture: the view (recent.html.erb) looks entirely static on its
  # own, but renders a PARTIAL (_meta.html.erb) that reads current_user --
  # proves the transitive scan follows `render partial:` targets, not just
  # the view's own body.
  def recent; end

  # A1 fixture: the view (featured.html.erb) renders `@post` -- Rails'
  # implicit object-to-partial shorthand, which names no partial file
  # statically -- proves an unresolvable render target keeps a route off
  # `content` rather than being silently skipped.
  def featured
    @post = Post.first
  end
end
