# Read-only prize catalog backed by config/prizes.yml (placeholder data until the shop is final).
Prize = Data.define(:key, :name, :description, :hours, :price_usd, :emoji, :image, :tier) do
  def self.all
    @all ||= Rails.application.config_for(:prizes)[:prizes].map { |attrs| new(**attrs) }.freeze
  end

  def self.keys = all.map(&:key)

  def self.find(key) = all.find { |prize| prize.key == key.to_s }
end
