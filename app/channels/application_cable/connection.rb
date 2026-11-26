module ApplicationCable
  # The one websocket (/cable) a signed-in, onboarded player opens from the dashboard (boss_live_controller.js). Anyone else is turned
  # away at the handshake, before any channel is reached. The session is the same signed cookie the pages use, so there is no token to
  # pass around; only the person's id is kept on the connection (never the record), and nothing the sockets carry is about one person.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user_id

    def connect
      self.current_user_id = onboarded_user_id || reject_unauthorized_connection
    end

    private

    def onboarded_user_id
      id = request.session[:user_id]
      User.where(id: id).where.not(onboarded_at: nil).pick(:id) if id
    end
  end
end
