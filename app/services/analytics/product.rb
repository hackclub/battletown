module Analytics
  # The product events (plans/analytics.md, section 2: ships, boss, armoury orders, hours, streaks, notifications, NPS, quests, crews,
  # plinko). Each method is the ONE place that knows what an event carries, so a call site is a single line:
  #
  #   Analytics::Product.order_placed(order)
  #
  # Properties are enums, small whole numbers and catalogue keys only (never a name, text, address, id of a person or a precise figure), and the
  # person is always the owner of the thing (the ship's author, the order's buyer). Every event that a retry or a re-run could repeat carries a
  # `once:` key, so a settle that runs twice, a sync that reads the same totals or a duplicate notification records one event.
  #
  # An analytics problem never breaks the action it measures: whatever goes wrong while the event is worked out is logged by class name only and
  # swallowed (and the write itself is rescued by Analytics.track in production). The one exception is a call that names an event or property
  # that is not in config/analytics.yml: in test and development that raises, so a typo fails CI. Staff and simulated players record nothing
  # (Analytics.track), and nothing here reads or stores a person's details.
  module Product
    SHIPPED_STATUSES = %w[submitted approved rejected].freeze
    ACTOR_KINDS = %w[staff buyer system].freeze
    BANDS = { detractor: 0..6, passive: 7..8, promoter: 9..10 }.freeze
    CHANNELS = [ Notifications::Preferences::SLACK, Notifications::Preferences::EMAIL ].freeze
    PURCHASE_REFUSALS = {
      "Shop::InsufficientCoins" => "insufficient_coins",
      "Shop::NotVerified" => "eligibility", "Shop::NotEligible" => "eligibility", "Shop::NeedsRecheck" => "eligibility",
      "Orders::AddressError" => "address_missing", "Orders::NeedsAddress" => "address_missing",
      "Shop::ItemUnavailable" => "out_of_stock",
      "Orders::TooManyOpen" => "limit"
    }.freeze

    module_function

    # Runs the block; a failure while working an event out is logged (class only) and never reaches the caller. A typo in an event or property is the
    # one thing that still raises outside production.
    def guard(label)
      yield
      nil
    rescue Events::Invalid => error
      raise if Analytics.strict?

      log(label, error)
    rescue StandardError => error
      log(label, error)
    end

    def log(label, error)
      Rails.logger.warn("Analytics: #{label} not recorded (#{error.class})")
      nil
    end

    # ---- Ships and the boss: called from the subscribers on the *.battletown events (Analytics::Subscribers) ----

    # `nth` throughout is the ship's place among the person's shipped ships (submitted, approved or rejected), by submission time.
    def ship_submitted(ship)
      guard("ship_submitted") do
        next unless ship&.submitted_at

        Analytics.track(:ship_submitted, user: ship.user, once: "ship_submitted:#{ship.id}", hours_bucket: Buckets.hours(ship.coded_seconds),
                                         nth: nth(ship), after_rejection: after_rejection?(ship))
        boss_hit(ship)
      end
    end

    def ship_approved(ship)
      guard("ship_approved") do
        next unless ship&.status_approved? && ship.submitted_at && ship.reviewed_at

        Analytics.track(:ship_approved, user: ship.user, once: "ship_approved:#{ship.id}", hours_bucket: Buckets.hours(ship.approved_seconds || ship.coded_seconds),
                                        nth: nth(ship), waited: Buckets.waited(ship.submitted_at, ship.reviewed_at))
      end
    end

    # Never the reason.
    def ship_rejected(ship)
      guard("ship_rejected") do
        next unless ship&.status_rejected? && ship.submitted_at && ship.reviewed_at

        Analytics.track(:ship_rejected, user: ship.user, once: "ship_rejected:#{ship.id}", nth: nth(ship),
                                        waited: Buckets.waited(ship.submitted_at, ship.reviewed_at))
      end
    end

    def ship_withdrawn(ship)
      guard("ship_withdrawn") do
        next unless ship&.status_withdrawn? && ship.submitted_at

        Analytics.track(:ship_withdrawn, user: ship.user, once: "ship_withdrawn:#{ship.id}", nth: nth(ship))
      end
    end

    # Shipping is what damages the weekly boss, so a submitted ship is one hit on the boss of its week (UTC date, as Bosses::Damage reads it).
    def boss_hit(ship)
      boss = Boss.without_art_content.covering(ship.submitted_at.utc.to_date).first
      return unless boss

      Analytics.track(:boss_hit, user: ship.user, once: "boss_hit:#{ship.id}", boss_id: boss.id, hours_bucket: Buckets.hours(ship.coded_seconds))
    end

    # The ship whose hours brought the boss down: its owner is the person (Bosses::CheckDefeat records the defeat once).
    def boss_defeated(boss, ship)
      guard("boss_defeated") { Analytics.track(:boss_defeated, user: ship.user, once: "boss_defeated:#{boss.id}", boss_id: boss.id) }
    end

    # ---- The armoury ----

    # A new order (never a replay of one that exists): Shop::Purchase for coins, Shop::ClaimSticker for the free sticker.
    def order_placed(order)
      guard("order_placed") do
        Analytics.track(:order_placed, user: order.user, once: "order_placed:#{order.id}", item_key: order.prize_key, coins: order.coins, kind: order.kind)
      end
    end

    # Why a purchase did not go through. The reason is one of a fixed few, and the item is only recorded when it is a real catalogue key.
    def purchase_refused(user, prize_key, error)
      guard("purchase_refused") do
        reason = PURCHASE_REFUSALS.find { |klass, _| error.is_a?(klass.constantize) }&.last || "other"
        item = Prize.find(prize_key.to_s)&.key
        Analytics.track(:purchase_refused, user: user, reason: reason, item_key: item)
      end
    end

    # order_shipped / order_fulfilled / order_cancelled / order_refunded, from the existing order_*.battletown events (the actor is a kind, never a person).
    def order_changed(name, order_id, actor_kind)
      guard(name) do
        order = Order.includes(:user).find_by(id: order_id)
        next unless order

        kind = ACTOR_KINDS.include?(actor_kind.to_s) ? actor_kind.to_s : "system"
        Analytics.track(name, user: order.user, once: "#{name}:#{order.id}", actor_kind: kind)
      end
    end

    # ---- Hours, days and streaks ----

    # After Hours::Credit wrote a row (inside the user's lock): the first Hackatime hours, and the day crossing the 15-minute mark and the person's pace goal.
    # A day before the game starts counting for the person is not a coding day. Re-running a sync credits nothing, and each key is `once:` anyway.
    def hours_credited(user, entry)
      guard("hours_credited") do
        next unless entry.seconds.positive?

        # One index probe instead of an insert that conflicts on every later credit (and burns an event id each time).
        Analytics.track(:first_hours_credited, user: user, once: "first") if entry.source == "hackatime" && !AnalyticsEvent.exists?(user_id: user.id, dedupe_key: "first", name: "first_hours_credited")
        next if entry.local_date < Hours::Days.first_counted_date(user)

        after = HourEntry.where(user_id: user.id, local_date: entry.local_date).sum(:seconds)
        before = after - entry.seconds
        quick = Game::Config.current.quick_seconds
        Analytics.track(:quick_day_reached, user: user, once: "quick:#{entry.local_date.iso8601}") if before < quick && after >= quick
        goal = user.pace * 60
        if before < goal && after >= goal
          Analytics.track(:daily_goal_reached, user: user, once: "goal:#{entry.local_date.iso8601}", pace_minutes: user.pace)
        end
      end
    end

    # After Game::Settle wrote the day's row: the streak went on, was saved by the freeze, or ended (the length is bucketed). `previous` is the streak state
    # before the day and `result` the StreakCalculator result for it.
    def day_settled(user, date, previous, result)
      guard("day_settled") do
        key = "settle:#{date.iso8601}"
        if result.quick_met
          Analytics.track(:streak_extended, user: user, once: "#{key}:streak_extended", days_bucket: Buckets.days(result.state.streak_15))
        elsif result.freeze_used
          Analytics.track(:freeze_used, user: user, once: "#{key}:freeze_used", days_bucket: Buckets.days(previous.streak_15))
        elsif previous.streak_15.positive?
          Analytics.track(:streak_broken, user: user, once: "#{key}:streak_broken", days_bucket: Buckets.days(previous.streak_15))
        end
      end
    end

    # A changed daily pace: while signing up it is the onboarding choice, afterwards a later change (User, after save).
    def pace_set(user)
      guard("pace_set") do
        next unless user.pace_minutes

        Analytics.track(:pace_set, user: user, pace_minutes: user.pace_minutes, source: user.onboarded_at_before_last_save.nil? ? "onboarding" : "later")
      end
    end

    # ---- Messages, feedback, quests, crews, plinko ----

    # A message really delivered (never a row that was only skipped by an adapter that does not deliver), or one that failed for good.
    def notification_sent(row)
      guard("notification_sent") do
        Analytics.track(:notification_sent, user: row.user, once: "notification_sent:#{row.id}", kind: row.kind, channel: channel_of(row))
      end
    end

    def notification_failed(row, code)
      guard("notification_failed") do
        Analytics.track(:notification_failed, user: row.user, once: "notification_failed:#{row.id}", kind: row.kind, channel: channel_of(row), code: code)
      end
    end

    # The score and whether a comment was left, never the comment.
    def nps_answered(response)
      guard("nps_answered") do
        band = BANDS.find { |_, scores| scores.cover?(response.score) }&.first
        Analytics.track(:nps_answered, user: response.user, once: "nps_answered:#{response.id}", score: response.score, band: band,
                                       has_comment: response.comment.present?)
      end
    end

    def quest_completed(completion)
      guard("quest_completed") do
        Analytics.track(:quest_completed, user: completion.user, once: "quest_completed:#{completion.quest_id}", goal_key: completion.quest.goal_key)
      end
    end

    def team_joined(membership)
      guard("team_joined") { Analytics.track(:team_joined, user: membership.user, once: "team_joined:#{membership.id}") }
    end

    def plinko_dropped(drop)
      guard("plinko_dropped") { Analytics.track(:plinko_dropped, user: drop.user, once: "plinko_dropped:#{drop.id}") }
    end

    # ---- helpers ----

    def nth(ship) = Buckets.nth(shipped_before(Ship.where(user_id: ship.user_id), ship).count + 1)

    # The ship before this one on the same project was decided against: this is the "fix and ship again".
    def after_rejection?(ship)
      shipped_before(Ship.where(project_id: ship.project_id, status: %w[approved rejected]), ship).order(:submitted_at, :id).last&.status_rejected? || false
    end

    # The ships (submitted, approved or rejected) that came before `ship`: earlier submission, the id breaking a tie.
    def shipped_before(scope, ship)
      scope.where(status: SHIPPED_STATUSES).where("ships.submitted_at < :at OR (ships.submitted_at = :at AND ships.id < :id)", at: ship.submitted_at, id: ship.id)
    end

    def channel_of(row) = CHANNELS.include?(row.channel) ? row.channel : nil

    private_class_method :boss_hit
  end
end
