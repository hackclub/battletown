module Api
  # The data-deletion protocol of Hack Club's "yeet" service (docs/PRIVACY_API.md). Authenticated only by the signed
  # bearer token and acting only on its claims, never on a body, query string, cookie or session: it inherits
  # ActionController::API on purpose, so none of ApplicationController's session or login behaviour is involved (and no
  # cookie is ever set). JSON only, never cached. Logs only the request id and the outcome.
  class PrivacyController < ActionController::API
    ENDPOINTS = %w[delete export].freeze

    before_action :private_response
    around_action :silence_sql_logging
    before_action :authenticate!, only: %i[delete export]

    rescue_from StandardError do |error|
      fail_with :internal_server_error, "internal_error", outcome: "error", detail: error.class.name
    end
    rescue_from Privacy::Jwks::Unavailable do
      fail_with :service_unavailable, "jwks_unavailable", outcome: "jwks_unavailable"
    end
    rescue_from ActiveRecord::ConnectionNotEstablished, ActiveRecord::QueryAborted, ActiveRecord::TransactionRollbackError do |error|
      fail_with :service_unavailable, "database_unavailable", outcome: "database_unavailable", detail: error.class.name
    end

    def delete
      respond Privacy::Deleter.new(@claims.subject).call(dry_run: @claims.dry_run)
    end

    # What this app holds about the person: the same counts a dry-run deletion reports, never changing anything,
    # whatever the token's dry_run says (the real work is rolled back).
    def export
      respond Privacy::Deleter.new(@claims.subject).call(dry_run: true)
    end

    # Anything else under /api/privacy: a JSON 405 for the two endpoints with the wrong verb, a JSON 404 otherwise.
    def fallback
      if ENDPOINTS.include?(params[:path])
        response.headers["Allow"] = "POST"
        render json: { error: "method_not_allowed" }, status: :method_not_allowed
      else
        render json: { error: "not_found" }, status: :not_found
      end
    end

    private

    def private_response
      response.headers["Cache-Control"] = "no-store"
      # Never write a session cookie, even to refresh one a browser happened to send.
      request.session_options[:skip] = true
    end

    # At debug level Active Record logs each query with its values, which here include the person's email.
    def silence_sql_logging(&block)
      logger = ActiveRecord::Base.logger
      logger ? logger.silence(Logger::INFO, &block) : yield
    end

    def authenticate!
      @claims = Privacy::TokenVerifier.new.verify!(bearer_token)
      return fail_with(:bad_request, "action_mismatch", outcome: "action_mismatch") unless @claims.action == action_name

      PrivacyRequestToken.consume!(@claims)
      PrivacyRequestToken.purge_expired
    rescue Privacy::TokenVerifier::Invalid
      fail_with :unauthorized, "invalid_token", outcome: "invalid_token"
    rescue PrivacyRequestToken::Replayed
      fail_with :conflict, "replayed", outcome: "replayed"
    end

    def bearer_token
      request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
    end

    def respond(result)
      log "ok"
      render json: {
        request_id: @claims.request_id,
        dry_run: @claims.dry_run,
        found: result.found,
        deleted: result.deleted,
        retained: result.retained
      }
    end

    def fail_with(status, code, outcome:, detail: nil)
      log outcome, detail
      render json: { error: code }, status: status
    end

    # Only the request id (from a verified token, so absent before verification) and the outcome; never a token,
    # an address or an identifier of the person.
    def log(outcome, detail = nil)
      line = +"privacy"
      line << " request_id=#{@claims.request_id}" if @claims
      line << " action=#{action_name} outcome=#{outcome}"
      line << " detail=#{detail}" if detail
      Rails.logger.info(line)
    end
  end
end
