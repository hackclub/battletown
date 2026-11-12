module AdminUsers
  # The staff user list (/admin/users): search, filters, sort and paging, in a fixed number of queries however many people
  # are listed (a count, one aggregate row for the header, one page of rows with their coin balance, hours total and last
  # coded date worked out in SQL).
  #
  #   result = AdminUsers::Directory.call(params)   # ActionController::Parameters or a Hash
  #   result.rows, result.pager, result.totals, result.query (the cleaned-up request, to fill the form)
  #
  # Privacy: a row holds a display name, status flags and counts. No email, Slack id or Hack Club Auth id is ever selected for the
  # list; they can be SEARCHED (exact match, Slack id and Hack Club Auth id as typed, email without regard to case) but never
  # shown. The search text is bound as a SQL parameter named like the column (`email`, `display_name`, `slack_id`, `hca_uid`),
  # which the filter list in config/initializers/filter_parameter_logging.rb hides from the SQL log, and the request parameter
  # `q` is filtered from the request log.
  class Directory
    SEARCH_FIELDS = %w[name slack_id hca_uid email].freeze
    SEARCH_LABELS = { "name" => "Display name contains", "slack_id" => "Slack id is", "hca_uid" => "Hack Club Auth id is", "email" => "Email is" }.freeze
    TRISTATE = %w[yes no].freeze
    NAME_MAX = 100
    EXACT_MAX = 254
    SORTS = {
      "newest" => "users.signed_up_on DESC, users.id DESC",
      "oldest" => "users.signed_up_on ASC, users.id ASC",
      "name" => "LOWER(COALESCE(users.display_name, '')) ASC, users.id ASC",
      "coins" => "coins DESC, users.id DESC",
      "hours" => "seconds DESC, users.id DESC",
      "last_coded" => "last_coded DESC NULLS LAST, users.id DESC"
    }.freeze
    SORT_LABELS = { "newest" => "Newest first", "oldest" => "Oldest first", "name" => "Name A to Z", "coins" => "Most coins",
                    "hours" => "Most hours", "last_coded" => "Coded most recently" }.freeze

    Row = Data.define(:id, :display_name, :verification_status, :ysws_eligible, :onboarded, :signed_up_on, :coins, :seconds,
                      :last_coded, :hackatime)
    Totals = Data.define(:users, :onboarded, :verified, :eligible, :hackatime)
    # The cleaned request: every value is either a known choice or nil/blank.
    Query = Data.define(:by, :q, :onboarded, :verified, :eligible, :hackatime, :referral, :from, :to, :sort) do
      def searching? = q.present?
    end
    Result = Data.define(:rows, :pager, :totals, :query)

    def self.call(params) = new(params).call

    def initialize(params)
      @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h.with_indifferent_access : params.to_h.with_indifferent_access
    end

    def call
      query = build_query
      scope = filtered(query)
      totals = totals_for(scope)
      pager = AdminPager.new(total: totals.users, page: @params[:page])
      Result.new(rows: rows_for(scope, query, pager), pager: pager, totals: totals, query: query)
    end

    private

    def build_query
      by = SEARCH_FIELDS.include?(@params[:by].to_s) ? @params[:by].to_s : "name"
      Query.new(by: by, q: clean_text(@params[:q]), onboarded: tristate(:onboarded), verified: tristate(:verified),
                eligible: tristate(:eligible), hackatime: tristate(:hackatime), referral: referral, from: date(:from), to: date(:to),
                sort: SORTS.key?(@params[:sort].to_s) ? @params[:sort].to_s : "newest")
    end

    # Text from the form: a string without NUL bytes (Postgres refuses them), trimmed and cut to a sane length.
    def clean_text(raw) = raw.is_a?(String) ? raw.delete("\u0000").strip.first(300) : ""

    def tristate(name) = (@params[name].to_s if TRISTATE.include?(@params[name].to_s))

    def referral
      value = @params[:referral].to_s
      value if value == "none" || value.match?(Referral::FORMAT)
    end

    def date(name)
      text = @params[name].to_s
      return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      parsed = Date.iso8601(text)
      parsed if parsed.year.between?(2000, 2100)
    rescue ArgumentError
      nil
    end

    def filtered(query)
      scope = search(User.all, query)
      scope = scope.where(onboarded_at: nil) if query.onboarded == "no"
      scope = scope.where.not(onboarded_at: nil) if query.onboarded == "yes"
      scope = scope.where(verification_status: "verified") if query.verified == "yes"
      scope = scope.where.not(verification_status: "verified") if query.verified == "no"
      scope = scope.where(ysws_eligible: query.eligible == "yes") if query.eligible
      scope = scope.where(HackatimeConnection.where("hackatime_connections.user_id = users.id").arel.exists) if query.hackatime == "yes"
      scope = scope.where.not(HackatimeConnection.where("hackatime_connections.user_id = users.id").arel.exists) if query.hackatime == "no"
      scope = query.referral == "none" ? scope.where(referral_source: nil) : scope.where(referral_source: query.referral) if query.referral
      scope = scope.where(signed_up_on: query.from..) if query.from
      scope = scope.where(signed_up_on: ..query.to) if query.to
      scope
    end

    def search(scope, query)
      return scope unless query.searching?

      text = query.q
      case query.by
      when "slack_id" then text.length > EXACT_MAX ? scope.none : scope.where(slack_id: text)
      when "hca_uid" then text.length > EXACT_MAX ? scope.none : scope.where(hca_uid: text)
      when "email" then text.length > EXACT_MAX ? scope.none : scope.where(lower_email_matches(text))
      else scope.where(name_matches(text.first(NAME_MAX)))
      end
    end

    # Case-insensitive substring of the display name. LIKE wildcards in what was typed are escaped, and the pattern is a bound
    # parameter called display_name (so a debug-level SQL log shows [FILTERED], never the text).
    def name_matches(text)
      pattern = "%#{User.sanitize_sql_like(text)}%"
      User.arel_table[:display_name].matches(bound(:display_name, pattern), "\\", false)
    end

    # Exact email, ignoring case: LOWER(email) = the typed address lower-cased, as a bound parameter called email.
    def lower_email_matches(text)
      Arel::Nodes::NamedFunction.new("LOWER", [ User.arel_table[:email] ]).eq(bound(:email, text.downcase))
    end

    def bound(column, value)
      Arel::Nodes::BindParam.new(ActiveRecord::Relation::QueryAttribute.new(column.to_s, value, ActiveModel::Type::String.new))
    end

    def totals_for(scope)
      counts = scope.reorder(nil).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE users.onboarded_at IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE users.verification_status = 'verified')"),
        Arel.sql("COUNT(*) FILTER (WHERE users.ysws_eligible)"),
        Arel.sql("COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM hackatime_connections hc WHERE hc.user_id = users.id))")
      )
      Totals.new(*Array(counts || Array.new(5, 0)).map(&:to_i)) # a search that can match nothing (`none`) has no row to pick
    end

    def rows_for(scope, query, pager)
      page = scope.joins(Arel.sql("LEFT JOIN (#{coin_totals_sql}) coin_totals ON coin_totals.user_id = users.id"))
                  .joins(Arel.sql("LEFT JOIN (#{hour_totals_sql}) hour_totals ON hour_totals.user_id = users.id"))
                  .select("users.id", "users.display_name", "users.verification_status", "users.ysws_eligible", "users.onboarded_at",
                          "users.signed_up_on", "COALESCE(coin_totals.coins, 0) AS coins", "COALESCE(hour_totals.seconds, 0) AS seconds",
                          "hour_totals.last_coded AS last_coded",
                          "EXISTS (SELECT 1 FROM hackatime_connections hc WHERE hc.user_id = users.id) AS hackatime")
                  .reorder(Arel.sql(SORTS.fetch(query.sort)))
      pager.apply(page).map do |user|
        Row.new(id: user.id, display_name: user.display_name, verification_status: user.verification_status, ysws_eligible: user.ysws_eligible,
                onboarded: user.onboarded_at.present?, signed_up_on: user.signed_up_on, coins: user[:coins].to_i, seconds: user[:seconds].to_i,
                last_coded: user[:last_coded], hackatime: user[:hackatime])
      end
    end

    def coin_totals_sql = "SELECT user_id, SUM(amount) AS coins FROM coin_transactions GROUP BY user_id"

    # The same rule as Hours::Totals: only dates the game counts (from the sign-up date), each day's net floored at zero.
    # last_coded is the latest such date with any time on it.
    def hour_totals_sql
      cutoff = Integer(Hours::Config.current.days_before_signup_counted)
      <<~SQL.squish
        SELECT per_day.user_id, SUM(per_day.day_seconds) AS seconds, MAX(per_day.local_date) FILTER (WHERE per_day.day_seconds > 0) AS last_coded
        FROM (
          SELECT h.user_id, h.local_date, GREATEST(SUM(h.seconds), 0) AS day_seconds
          FROM hour_entries h JOIN users su ON su.id = h.user_id
          WHERE h.local_date >= su.signed_up_on - #{cutoff}
          GROUP BY h.user_id, h.local_date
        ) per_day
        GROUP BY per_day.user_id
      SQL
    end
  end
end
