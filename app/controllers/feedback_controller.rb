# /feedback/:token: the one-click NPS survey that the Slack DM links to (flag `nps`: no route exists while it is off).
#
# PUBLIC BY DESIGN: it works without logging in, so a click from Slack just works. The signed token in the path (Nps::Token:
# purpose-scoped, tamper-proof, expires after `nps.token_ttl_days`) is the only credential, and it can do exactly one thing:
# answer the survey once for its prompt window. Nothing personal is ever rendered here (no name, email, score or comment of
# anyone: a repeat visit says only "you already answered"), and a bad, tampered, expired or unknown token all get the same
# page, so it reveals nothing about who exists. Writes keep CSRF protection (the form carries the authenticity token).
class FeedbackController < ApplicationController
  before_action :private_page
  before_action :load_claims

  def show
    return render(:thanks, locals: { again: true }) if answered?

    @score = nil
    @comment = nil
  end

  def create
    return render(:thanks, locals: { again: true }) if answered?

    answer = params[:nps].is_a?(ActionController::Parameters) ? params[:nps].permit(:score, :comment) : {}
    @score = answer[:score].to_s
    @comment = NpsResponse.clean_comment(answer[:comment])
    @errors = problems
    return render(:show, status: :unprocessable_content) if @errors.any?

    save_answer
  end

  private

  # The link can sit in chat history, so keep the page and the link out of caches, search engines and Referer headers.
  def private_page
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end

  def load_claims
    @claims = Nps::Token.parse(params[:token])
    @user = @claims && User.find_by(id: @claims.user_id)
    render(:invalid, status: :not_found) unless @user
  end

  def answered?
    NpsResponse.exists?(user_id: @user.id, prompt_window_date: @claims.window_date)
  end

  def problems
    errors = []
    errors << "Pick a number from 0 to 10." unless @score.match?(/\A(?:10|[0-9])\z/)
    errors << "Keep your comment to #{NpsResponse::COMMENT_MAX} characters or fewer." if @comment.to_s.length > NpsResponse::COMMENT_MAX
    errors
  end

  def save_answer
    NpsResponse.create!(user: @user, score: @score.to_i, comment: @comment, answered_at: Time.current, prompt_window_date: @claims.window_date)
    render :thanks, locals: { again: false }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # A second tab or a double click answered first: the first answer stands.
    answered? ? render(:thanks, locals: { again: true }) : raise
  end
end
