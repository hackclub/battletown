# Bearer tokens that travel in the URL path (not the query string) must stay out of the logs too: Rails filters parameters
# in the query string only, and prints the raw path in "Started GET ...". Whoever can read the logs must not be able to
# open a crew invite, answer someone's survey or unsubscribe someone, so the token segment is replaced before it is logged.
#   /team/join/<token>  /feedback/<token>  /email/unsubscribe/<token>
module FilterPathTokens
  PATTERN = %r{\A(/team/join/|/feedback/|/email/unsubscribe/)[^/?#]+}

  def filtered_path
    @filtered_path_without_tokens ||= super.sub(PATTERN, '\1[FILTERED]')
  end
end

ActiveSupport.on_load(:action_controller_base) { ActionDispatch::Request.prepend(FilterPathTokens) }
