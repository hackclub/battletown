# Aggregate, PII-free numbers for the admin dashboard: only counts, never an email, name, Slack ID or uid.
# One grouped COUNT per breakdown (no per-user loads). Exact counts are shown: admins are staff, so small
# buckets are not masked (revisit with a "<5" rule if the dashboard is ever shared more widely).
class AdminStats
  SIGNUP_DAYS = 14

  Row = Data.define(:label, :count)
  Stats = Data.define(:total_users, :signups_per_day, :onboarding_funnel, :onboarded, :verification, :referral_sources,
                      :prizes, :project_kinds)

  def self.call(today: Time.current.utc.to_date) = new(today: today).call

  def initialize(today:)
    @today = today
  end

  def call
    Stats.new(
      total_users: User.count,
      signups_per_day: signups_per_day,
      onboarding_funnel: onboarding_funnel,
      onboarded: User.where.not(onboarded_at: nil).count,
      verification: verification,
      referral_sources: referral_sources,
      prizes: prizes,
      project_kinds: project_kinds
    )
  end

  private

  # Last SIGNUP_DAYS UTC days, oldest first, zero-filled.
  def signups_per_day
    first_day = @today - (SIGNUP_DAYS - 1)
    counts = User.where(created_at: first_day.beginning_of_day..@today.end_of_day)
                 .group(Arel.sql("(users.created_at AT TIME ZONE 'UTC')::date")).count
                 .transform_keys { |day| day.to_date }
    (first_day..@today).map { |day| Row.new(label: day.iso8601, count: counts.fetch(day, 0)) }
  end

  # "Reached at least step N" for N = 0..ONBOARDING_STEPS, from one grouped query.
  def onboarding_funnel
    by_step = User.group(:onboarding_step).count
    (0..User::ONBOARDING_STEPS).map do |step|
      Row.new(label: "Step #{step}", count: by_step.sum { |reached, count| reached >= step ? count : 0 })
    end
  end

  def verification
    counts = User.group(:verification_status).count
    User.verification_statuses.keys.map { |status| Row.new(label: status.humanize, count: counts.fetch(status, 0)) }
  end

  # Known keys use their display name; stored keys we do not recognise are folded into "other"; no answer is its own row.
  def referral_sources
    counts = User.group(:referral_source).count
    other = ReferralSource.other
    known = ReferralSource.all.map(&:key)
    rows = ReferralSource.all.map { |source| Row.new(label: source.name, count: counts.fetch(source.key, 0)) }
    unknown = counts.sum { |key, count| key.nil? || known.include?(key) ? 0 : count }
    rows.map! { |row| row.label == other.name ? row.with(count: row.count + unknown) : row }
    rows << Row.new(label: "No answer", count: counts.fetch(nil, 0))
    rows.reject { |row| row.count.zero? }
  end

  def prizes
    counts = User.group(:prize_key).count
    rows = Prize.paid.map { |prize| Row.new(label: prize.name, count: counts.fetch(prize.key, 0)) }
    # An archived item stays in the stats for as long as anyone still has it picked.
    archived = Prize.all.reject(&:active?).filter_map do |prize|
      Row.new(label: "#{prize.name} (archived)", count: counts.fetch(prize.key, 0)) if counts.fetch(prize.key, 0).positive?
    end
    rows.concat(archived)
    rows << Row.new(label: "No pick yet", count: counts.fetch(nil, 0))
    retired = counts.sum { |key, count| key.nil? || Prize.find(key) ? 0 : count }
    rows << Row.new(label: "Prize no longer offered", count: retired) if retired.positive?
    rows
  end

  def project_kinds
    counts = User.group(:project_kind).count
    rows = User::PROJECT_KINDS.map { |kind| Row.new(label: kind.humanize, count: counts.fetch(kind, 0)) }
    rows << Row.new(label: "Not chosen", count: counts.fetch(nil, 0))
  end
end
