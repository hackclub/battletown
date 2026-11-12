module AdminUsers
  # Everything on one person's staff page (/admin/users/:id), gathered in a handful of queries whatever they have done.
  # Read-only. It selects no tokens (the Hackatime connection is read for its state only), no message text (the notification
  # outbox is only counted) and nothing that is not stored (phone, birthday and address are never kept).
  class Profile
    HOURS_DAYS = 28
    LEDGER_ROWS = 50
    ORDER_ROWS = 20
    NOTE_ROWS = 30
    AUDIT_ROWS = 30

    DayRow = Data.define(:date, :seconds, :adjustment_seconds, :settled, :counted)
    HackatimeState = Data.define(:connected, :last_synced_at, :needs_reconnect, :last_error_code)

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def today = @today ||= Hours::Days.today(user.time_zone)

    def balance = @balance ||= Coins::Balance.total(user)

    def spend_state = user.spend_state

    def hackatime
      @hackatime ||= begin
        connection = HackatimeConnection.where(user_id: user.id).select(:id, :last_synced_at, :needs_reconnect, :last_error_code).take
        HackatimeState.new(connected: connection.present?, last_synced_at: connection&.last_synced_at,
                           needs_reconnect: connection&.needs_reconnect || false, last_error_code: connection&.last_error_code)
      end
    end

    # Flag-guarded facts: nothing is read while the feature's flag is off, so a flagged-off table is never touched.
    def extras
      @extras ||= {}.tap do |list|
        list["Crew member"] = TeamMembership.exists?(user_id: user.id) ? "yes" : "no" if Features.enabled?(:team)
        list["Survey answers"] = NpsResponse.where(user_id: user.id).count if Features.enabled?(:nps)
        list["Plinko balls dropped"] = PlinkoDrop.where(user_id: user.id).count if Features.enabled?(:plinko)
      end
    end

    def projects = @projects ||= Project.where(user_id: user.id).includes(:ships).order(:created_at, :id).to_a

    def ledger = @ledger ||= CoinTransaction.where(user_id: user.id).order(created_at: :desc, id: :desc).limit(LEDGER_ROWS).to_a

    def orders = @orders ||= Order.where(user_id: user.id).order(created_at: :desc, id: :desc).limit(ORDER_ROWS).to_a

    def notes = @notes ||= UserNote.where(user_id: user.id).includes(:author).newest_first.limit(NOTE_ROWS).to_a

    def audit_events = @audit_events ||= AdminAuditEvent.about("User", user.id).includes(:actor).newest_first.limit(AUDIT_ROWS).to_a

    # Net coded seconds per local date for the last 28 days, newest first, with the part that came from staff adjustments, whether
    # the day has settled into a streak result, and whether the game counts the date at all.
    def hours_by_day
      @hours_by_day ||= begin
        dates = (today - (HOURS_DAYS - 1))..today
        sums = HourEntry.where(user_id: user.id, local_date: dates).group(:local_date)
                        .pluck(:local_date, Arel.sql("SUM(seconds)"), Arel.sql("SUM(CASE WHEN source = 'adjustment' THEN seconds ELSE 0 END)"))
                        .to_h { |date, seconds, adjusted| [ date, [ seconds.to_i, adjusted.to_i ] ] }
        settled = DailyResult.where(user_id: user.id, local_date: dates).pluck(:local_date).to_set
        first = Hours::Days.first_counted_date(user)
        dates.to_a.reverse.map do |date|
          seconds, adjusted = sums.fetch(date, [ 0, 0 ])
          DayRow.new(date: date, seconds: seconds, adjustment_seconds: adjusted, settled: settled.include?(date), counted: date >= first)
        end
      end
    end

    def streak = @streak ||= DailyResult.where(user_id: user.id).order(local_date: :desc).first

    def settled_days = @settled_days ||= DailyResult.where(user_id: user.id).count

    # { kind => { status => count } }: how much is queued or sent, never what it says.
    def outbox
      @outbox ||= Notification.where(user_id: user.id).group(:kind, :status).count
                              .each_with_object(Hash.new { |hash, key| hash[key] = {} }) { |((kind, status), count), grouped| grouped[kind][status] = count }
    end
  end
end
