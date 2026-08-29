class PostsController < ApplicationController
  layout :choose # dynamic (symbol) layout -- RAILS_LAYOUT_DYNAMIC pinned at this line (L2)

  # index.html.erb reads @posts (an ivar, inside `.each`) -- REQUEST_TIME_STATE
  # -- and renders `_post` with non-literal locals -- PARTIAL_DYNAMIC.
  def index
    @posts = Post.all
  end

  # show.html.erb reads @post.title -- REQUEST_TIME_STATE.
  def show
    @post = Post.find(params[:id])
  end

  private

  # `layout :choose` never actually resolves via THIS method (Stage 1 does
  # not evaluate Ruby); it exists only to make the dynamic layout
  # declaration look like real Rails code, not a dangling symbol.
  def choose
    "application"
  end
end
