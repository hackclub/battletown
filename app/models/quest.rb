# The weekly quest: one per boss week (`starts_on` is a boss's first day, `ends_on` its last), a goal from the fixed
# code-defined menu (Quests::Goals), the goal's number in `goal_params` (`{ "target" => 3 }` for goals that count days)
# and a flat reward in coins, paid with the user's next approved ship (Quests::Payout). It names no user and holds no
# free text: the words shown are config copy for the goal key (config/game.yml, `quests:`).
#
# Set by an admin (Admin::QuestsController). It can be changed until its week has started (`started?`, the same rule
# as a boss's health: the first day has begun in the earliest time zone on Earth); after that nothing about it may
# change, because people are already working toward it. Dates are fixed once saved.
class Quest < ApplicationRecord
  GOAL_KEYS = Quests::Goals::KEYS
  # The most any quest may pay, whatever config says (the database checks the same bound).
  REWARD_CEILING = 1000
  # A week that has already ended in the latest time zone (UTC-12) can no longer be given a quest.
  LATEST_ZONE = "Etc/GMT+12".freeze

  has_many :completions, class_name: "QuestCompletion", dependent: nil, inverse_of: :quest

  before_validation :take_ends_on_from_boss

  validates :starts_on, :ends_on, presence: true
  validates :starts_on, uniqueness: { message: "already has a quest" }
  validates :goal_key, inclusion: { in: GOAL_KEYS }
  validates :reward_coins, numericality: { only_integer: true, greater_than: 0 }
  validate :aligned_with_a_boss_week
  validate :goal_is_on_the_menu, on: :create
  validate :target_fits_goal
  validate :week_not_over, on: :create
  validate :reward_within_config
  validate :dates_fixed, on: :update
  validate :fixed_once_started, on: :update

  scope :chronological, -> { order(:starts_on) }
  scope :newest_first, -> { order(starts_on: :desc) }
  scope :covering, ->(date) { where(starts_on: ..date, ends_on: date..) }

  def self.for_date(date) = covering(date).first

  # Boss weeks that can still be given a quest: not over yet and without one. What the admin form offers.
  def self.open_weeks
    Boss.where(ends_on: Time.current.in_time_zone(LATEST_ZONE).to_date..).where.not(starts_on: select(:starts_on)).chronological
  end

  # { quest id => { completed:, paid:, coins: } } for the admin list: counts and a coin total over everyone, never who.
  def self.stats(quests)
    sums = QuestCompletion.where(quest_id: quests.map(&:id)).left_joins(:coin_transaction).group(:quest_id)
                          .pluck(:quest_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(quest_completions.coin_transaction_id)"), Arel.sql("COALESCE(SUM(coin_transactions.amount), 0)"))
    stats = Hash.new { { completed: 0, paid: 0, coins: 0 } }
    sums.each { |id, completed, paid, coins| stats[id] = { completed: completed, paid: paid, coins: coins.to_i } }
    stats
  end

  def range = starts_on..ends_on

  def target = goal_params["target"]&.to_i || 1

  def goal = Quests::Config.current.goals[goal_key]

  def title = goal&.title_for(target, Quests::Config.current.quick_minutes)

  def description = goal&.description_for(target, Quests::Config.current.quick_minutes)

  # The week's first day has begun somewhere on Earth, so people may already be working toward it.
  def started?(now: Time.current)
    return false if starts_on.nil?

    now.in_time_zone(Boss::EARLIEST_ZONE).to_date >= starts_on
  end

  # The admin form sends the goal's number as `target`; it lives in `goal_params`.
  def target=(value)
    self.goal_params = value.blank? ? {} : { "target" => Integer(value.to_s, 10) }
  rescue ArgumentError
    self.goal_params = { "target" => value.to_s }
  end

  def self.human_attribute_name(attribute, options = {})
    { "starts_on" => "Week", "goal_key" => "Goal", "reward_coins" => "Reward", "target" => "Number" }.fetch(attribute.to_s) { super }
  end

  private

  # Quests belong to a boss week: the date must be the first day of a boss, and the quest takes that boss's last day.
  def aligned_with_a_boss_week
    return if starts_on.nil?

    errors.delete(:ends_on)
    errors.add(:starts_on, "must be the first day of a boss week (pick a week from the list)") unless boss_week
  end

  def boss_week = Boss.find_by(starts_on: starts_on)

  def take_ends_on_from_boss
    self.ends_on = boss_week&.ends_on if starts_on
  end

  def goal_is_on_the_menu
    errors.add(:goal_key, "is not on the menu") if GOAL_KEYS.include?(goal_key) && !Quests::Config.current.allowed_goals.include?(goal_key)
  end

  def target_fits_goal
    return unless goal

    range = goal.target_range
    given = goal_params.is_a?(Hash) ? goal_params : {}
    extra = given.keys - (range ? [ "target" ] : [])
    return errors.add(:target, "is not used by this goal") if extra.any?
    return unless range

    value = given["target"]
    errors.add(:target, "must be a whole number from #{range.min} to #{range.max}") unless value.is_a?(Integer) && range.cover?(value)
  end

  def week_not_over
    return if ends_on.nil?

    errors.add(:starts_on, "is a week that is already over") if ends_on < Time.current.in_time_zone(LATEST_ZONE).to_date
  end

  def reward_within_config
    max = Quests::Config.current.max_reward_coins
    errors.add(:reward_coins, "can be at most #{max} coins") if reward_coins.is_a?(Integer) && reward_coins > max
  end

  def dates_fixed
    errors.add(:base, "A quest's week can't be changed") if starts_on_changed? || ends_on_changed?
  end

  def fixed_once_started
    return unless changed.any? { |name| %w[goal_key goal_params reward_coins].include?(name) }

    errors.add(:base, "This quest can't be changed once its week has started") if started?
  end
end
