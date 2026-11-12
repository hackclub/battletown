# GET /auth/hack_club_address/callback: the way back from the Hack Club Auth address round trip made at checkout (the OmniAuth
# strategy OmniAuth::Strategies::HackClubAddress has already checked state, nonce and PKCE and exchanged the code). Additive to
# sign-in: it never creates or signs in anyone.
#
# What it does, in this order: takes the pending checkout out of the session (so the callback works once), checks the Hack Club
# account that answered IS the signed-in person (else it keeps nothing), reads the person's saved addresses with the one-time
# token (Hca::Me), keeps them in an encrypted, 15-minute AddressOffer, and ALWAYS revokes the token, whatever happened. The token
# lives in this method's local variables and nowhere else: never in the session, the database, the logs or a flash.
class AddressCallbacksController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :no_store

  MESSAGES = {
    not_available: "Address lookup isn't available yet. Nothing was saved. Please message the team on Slack and we'll sort your delivery out.",
    unauthorized: "Hack Club Auth didn't accept that sign in, so nothing was saved. Please try again.",
    unavailable: "We couldn't reach Hack Club Auth, so nothing was saved. Try again in a minute.",
    bad_response: "Hack Club Auth sent something we couldn't read, so nothing was saved. Try again in a minute."
  }.freeze
  WRONG_ACCOUNT = "That wasn't the Hack Club account you're signed in to Battletown with, so nothing was saved. Try again with your own account.".freeze
  NO_REQUEST = "That took too long, so we started over. Open the item again and press the button.".freeze

  def create
    auth = request.env["omniauth.auth"]
    credentials = auth&.credentials
    tokens = [ credentials&.token, credentials&.refresh_token ].map(&:to_s).compact_blank
    context = Orders::AddressLookup.consume(session)
    return redirect_to(shop_path, alert: NO_REQUEST) unless context
    return redirect_to(Orders::AddressLookup.return_path(context), alert: WRONG_ACCOUNT) unless this_person?(auth)

    result = Hca::Me.addresses(tokens.first)
    AddressOffer.store!(user: current_user, draft_key: context["draft"], result: result)
    redirect_to Orders::AddressLookup.return_path(context)
  rescue Hca::LookupError => error
    redirect_to Orders::AddressLookup.return_path(context), alert: MESSAGES.fetch(error.code, MESSAGES[:unavailable])
  ensure
    Hca::TokenRevoker.call(*tokens) if tokens.present?
  end

  private

  # The account that just answered is the one signed in here (Hack Club Auth's id, the same as users.hca_uid).
  def this_person?(auth)
    auth&.provider.to_s == "hack_club_address" && auth.uid.to_s.present? && ActiveSupport::SecurityUtils.secure_compare(auth.uid.to_s, current_user.hca_uid.to_s)
  end

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
