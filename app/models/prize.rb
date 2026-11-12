# Read-only catalogue backed by config/prizes.yml (placeholder items until the designer's final shop lands).
# The one price is `coins`; `hours` is derived from it (coins / Game::Config coins_per_hour) for the landing page and
# onboarding, which talk in hours. The free signup sticker (`free_signup`) is not for sale: use `Prize.paid` for
# anything a person can pick or buy, and `Prize.keys` (every key, free one included) as the stored-key allowlist.
Prize = Data.define(:key, :name, :description, :coins, :emoji, :image, :tier, :free_signup) do
  def self.all
    @all ||= Rails.application.config_for(:prizes)[:prizes].map { |attrs| new(**attrs.reverse_merge(free_signup: false)) }.freeze
  end

  def self.paid = all.reject(&:free_signup)

  def self.free_signup = all.find(&:free_signup)

  def self.keys = all.map(&:key)

  def self.find(key) = all.find { |prize| prize.key == key.to_s }

  def free_signup? = free_signup == true

  # Hours of approved coding this costs before any bonus: a whole number, or one decimal place (rounded half up).
  def hours
    tenths = (coins * 10r / Game::Config.current.coins_per_hour).round
    (tenths % 10).zero? ? tenths / 10 : tenths / 10.0
  end

  # "2 hours", "1 hour", "1.5 hours".
  def hours_text
    value = hours
    "#{value} #{value == 1 ? 'hour' : 'hours'}"
  end
end
