# One-click unsubscribe for Battletown email (docs/CONTRACT.md, "Email notifications"): GET/POST /email/unsubscribe/:token.
# No sign-in: the signed token (Notifications::Email::UnsubscribeToken) is the credential, and all it can do is switch
# one person's email off.
#
# - GET only shows a page with a button and changes nothing, so a mail scanner or link previewer that fetches the link
#   cannot unsubscribe anyone.
# - POST does it. It is the target of both the button and the RFC 8058 `List-Unsubscribe-Post` one-click request from
#   mail providers (a body of `List-Unsubscribe=One-Click`, no cookies, no CSRF token, not a browser). So this one action
#   skips CSRF protection, because the token authenticates it, and the browser check (it is not a browser); nothing else
#   in the app is exempt.
# - Idempotent, and a bad, rotated or deleted-account token gets the same generic page as everything else (never a hint
#   about which accounts exist). The page shows no name and no address.
# - Behind the Flipper flag `email`: the routes do not exist while it is off, and this re-checks.
class EmailUnsubscribesController < ApplicationController
  skip_forgery_protection only: :create
  before_action { require_feature!(:email) }
  before_action :private_response

  def show
    @user = Notifications::Email::UnsubscribeToken.user_for(params[:token])
    @state = @user ? (@user.email_opted_out? ? :done : :confirm) : :invalid
  end

  def create
    user = Notifications::Email::UnsubscribeToken.user_for(params[:token])
    Notifications::Email::Subscription.unsubscribe!(user) if user
    @state = user ? :done : :invalid
    render :show
  end

  private

  def skip_browser_check? = action_name == "create"

  # The token is in the address: keep it out of caches, referrers and search engines.
  def private_response
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end
end
