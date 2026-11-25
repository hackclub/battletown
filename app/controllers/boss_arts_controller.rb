# Serves a boss's own picture (the re-encoded WebP kept in bosses; see Boss). Public on purpose: the landing page and the
# dashboard show the boss to anyone who can see them, and a boss is not about a person. The picture is the same for everyone, so
# it is cached by the browser for a day (private: no shared cache keeps it), revalidated by ETag (the SHA-256 of the bytes), never
# sniffed into another type and never allowed to run anything. The URLs the pages use carry `?v=<hash prefix>`, so a replaced
# picture is fetched fresh at once. A boss that has not begun yet (next week's, added early) shows only as a date on the pages, so
# its picture is for staff only until its first day. A boss with no picture of its own, an unbegun one and an unknown id get the
# plain 404 an unknown path gets.
class BossArtsController < ApplicationController
  def show
    boss = Boss.without_art_content.find_by(id: params[:id])
    raise ActionController::RoutingError, "Not Found" unless boss&.art? && (boss.begun? || (signed_in? && current_user.admin?))

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "sandbox"
    expires_in 1.day, public: false
    return unless stale?(etag: boss.art_sha256, public: false)

    send_data Boss.art_content_for(boss.id), type: Boss::ART_CONTENT_TYPE, disposition: "inline"
  end
end
