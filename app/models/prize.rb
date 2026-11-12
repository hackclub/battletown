# The shop catalogue as the rest of the app reads it: a thin, read-only facade over the `shop_items` table (ShopItem), which
# staff edit at /admin/shop. Callers never touch ShopItem; they use this, and its public API is the one the app always had.
#
#   Prize.all          every item, ARCHIVED ones too, in the order staff set (position)
#   Prize.paid         what a person can pick or buy: active, not the free sticker (landing, onboarding picker, shop grid)
#   Prize.active       active items, the free sticker included
#   Prize.free_signup  the free signup sticker when it is on offer (active), else nil
#   Prize.find(key)    one item by key, archived or not (nil when unknown): orders and users keep working for archived items
#   Prize.keys         EVERY key, archived included: the allowlist for stored `users.prize_key` / `orders.prize_key`
#
# The one price is `coins`; `hours` is derived from it (coins / Game::Config coins_per_hour) for the landing page and
# onboarding, which talk in hours. `image` is a same-origin path to the uploaded picture (or an asset name from the YAML
# fallback), nil when there is none.
#
# The catalogue is read once per request (ShopItems::Catalogue) so a page adds one query however many times it asks, and
# it is dropped whenever an item changes. While the table is missing (boot, assets:precompile, before the migration) or
# empty (a fresh database nobody seeded), it falls back to config/prizes.yml, the default seed.
Prize = Data.define(:key, :name, :description, :coins, :emoji, :image, :tier, :free_signup, :active, :position) do
  def initialize(active: true, position: 0, **attributes) = super(active: active, position: position, **attributes)

  def self.all = ShopItems::Catalogue.items

  def self.active = all.select(&:active?)

  def self.paid = active.reject(&:free_signup?)

  def self.free_signup = active.find(&:free_signup?)

  def self.keys = all.map(&:key)

  def self.find(key) = all.find { |prize| prize.key == key.to_s }

  # Drops the per-request copy; the next call reads the table again.
  def self.reload! = ShopItems::Catalogue.reset

  def free_signup? = free_signup == true

  # Still on offer (not archived).
  def active? = active == true

  # Hours of approved coding `coins` cost before any bonus: a whole number, or one decimal place (rounded half up).
  def self.hours_for(coins)
    tenths = (coins * 10r / Game::Config.current.coins_per_hour).round
    (tenths % 10).zero? ? tenths / 10 : tenths / 10.0
  end

  # "2 hours", "1 hour", "1.5 hours".
  def self.hours_text_for(coins)
    value = hours_for(coins)
    "#{value} #{value == 1 ? 'hour' : 'hours'}"
  end

  def hours = self.class.hours_for(coins)

  def hours_text = self.class.hours_text_for(coins)
end
