module Features
  # The Flipper console (/admin/flipper) is a mounted Rack app, so none of the app's controllers run for it. This wraps it and
  # writes one audit row (AdminAudit, action feature_flag_changed) for every change an admin makes there: a POST, PATCH, PUT or
  # DELETE that the console answered with a success or a redirect. Looking at the console writes nothing. The row holds the
  # flag's name and the gate that changed (boolean, groups, actors ...), never an actor id or a value. A failure to write the row
  # is logged and never breaks the console (the change has already been made by then).
  class AuditedConsole
    READS = %w[GET HEAD OPTIONS].freeze
    NAME = /\A[a-z0-9_]{1,60}\z/

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      record(ActionDispatch::Request.new(env), status)
      [ status, headers, body ]
    end

    private

    def record(request, status)
      return if READS.include?(request.request_method) || status >= 400

      admin = User.find_by(id: request.session[:user_id])
      return unless admin&.admin?

      AdminAudit.record!(actor: admin, action: "feature_flag_changed", subject: [ "Flipper", 0 ], metadata: metadata(request))
    rescue StandardError => error
      Rails.logger.warn("Feature flag audit failed: #{error.class}")
    end

    # /admin/flipper/features/<name>/<gate> (the console's own paths).
    def metadata(request)
      parts = request.path_info.to_s.split("/").reject(&:empty?)
      index = parts.index("features")
      feature = parts[index + 1] if index
      gate = parts[index + 2] if index
      { http_method: request.request_method.downcase, feature: (feature if feature&.match?(NAME)), gate: (gate if gate&.match?(NAME)) }.compact
    end
  end
end
