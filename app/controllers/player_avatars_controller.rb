# GET /players/:slug/avatar: the small WebP copy of a player's Slack picture (SlackProfiles::Avatar). Signed in and onboarded
# only (the picture of a teen is never served to the open web), and it is NEVER Slack's address: this app serves its own re-encoded copy.
#
# One plain 404 (the same one as an unknown profile, ProfilesController) for everything that is not "a player who keeps a picture":
# an address nobody has, a picture that was turned off, deleted or never fetched. Those cannot be told apart.
# The answer is private (never a shared cache) and revalidated by ETag; the address a page uses carries the picture's version
# (`?v=`), so a changed picture is a new address and the old one can be kept for a while.
class PlayerAvatarsController < ApplicationController
  before_action :require_login, :require_onboarded

  def show
    owner = User.by_slug(params[:slug])
    row = owner && SlackProfile.where(user_id: owner.id, use_picture: true).with_picture.select(:picture, :picture_sha256).first
    raise ActiveRecord::RecordNotFound unless row

    expires_in 1.hour, public: false, must_revalidate: true
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data row.picture, type: SlackProfile::CONTENT_TYPE, disposition: "inline" if stale?(etag: row.picture_sha256, public: false)
  end
end
