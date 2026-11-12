module Notifications
  module Email
    # The signed link in every email's footer and List-Unsubscribe header. A token carries nothing but the person's id
    # and their `email_unsubscribe_nonce`, signed (MessageVerifier, HMAC-SHA256, URL-safe) for this purpose only, so it
    # cannot be used for anything else and no other signed value in the app can be replayed here. No address is in it.
    #
    # It never expires, but it is revocable: turning email back on rotates the person's nonce, which kills every link
    # already sent (and a new email carries a new one). A forwarded link can only switch that one person's email off.
    # Verification fails closed: a bad signature, a deleted person or a rotated nonce are all just `nil`.
    module UnsubscribeToken
      PURPOSE = "email_unsubscribe".freeze
      MAX_LENGTH = 300

      module_function

      def generate(user)
        verifier.generate([ user.id, user.email_unsubscribe_nonce ], purpose: PURPOSE)
      end

      # The User the token is good for, or nil. Constant-time on the nonce.
      def user_for(token)
        return nil unless token.is_a?(String) && token.length <= MAX_LENGTH

        id, nonce = verifier.verified(token, purpose: PURPOSE)
        return nil unless id.is_a?(Integer) && nonce.is_a?(String)

        user = User.find_by(id: id)
        user if user && ActiveSupport::SecurityUtils.secure_compare(user.email_unsubscribe_nonce, nonce)
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def verifier
        @verifier ||= ActiveSupport::MessageVerifier.new(
          Rails.application.key_generator.generate_key("battletown email unsubscribe v1"),
          digest: "SHA256", serializer: JSON, url_safe: true
        )
      end
    end
  end
end
