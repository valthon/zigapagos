class PostsController < ApplicationController
  before_action :require_login, only: [:index] # -- RAILS_ROUTE_AUTH_GUARD
  layout :choose # dynamic (symbol) layout -- RAILS_LAYOUT_DYNAMIC pinned at this line (L3)

  # index.html.erb reads @posts (an ivar, inside `.each`) -- REQUEST_TIME_STATE
  # -- and renders `_post` with non-literal locals -- PARTIAL_DYNAMIC.
  def index
    @posts = Post.all
  end

  # Stage 5 parity: a conventional title/body form whose create route is
  # bound to the conditional ZigBase createPosts operation.
  def new
    @post = Post.new
  end

  def create
    # The generated form island owns this mutation after the operator binds it.
  end

  # show.html.erb reads @post.title -- REQUEST_TIME_STATE.
  def show
    @post = Post.find(params[:id])
  end

  # #167 Stage 3: renders JSON, so the route has no view to convert and the
  # handoff calls it `backend`. Under assumption A2 a user-facing GET with
  # that status is UNACCOUNTED until an operation is chosen for it -- this
  # is the one action in the fixture that makes `--backend` load-bearing
  # rather than merely widening a `choices` list.
  def feed
    render json: Post.all
  end

  private

  # #167 Stage 3, assumption A7: a `before_action` whose name reads like an
  # auth check. A static page cannot enforce it, so the route is not
  # silently shipped -- RAILS_ROUTE_AUTH_GUARD asks, and `public` is the
  # answer that says "the ZigBase rules protect the data".
  def require_login
    redirect_to new_session_path unless session[:user_id]
  end

  # `layout :choose` never actually resolves via THIS method (Stage 1 does
  # not evaluate Ruby); it exists only to make the dynamic layout
  # declaration look like real Rails code, not a dangling symbol.
  def choose
    "application"
  end
end
