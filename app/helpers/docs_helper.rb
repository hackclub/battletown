# Numbers the /docs page quotes, read from the same config the game uses, so the page stays true when a value is tuned.
module DocsHelper
  def docs_game = Game::Config.current

  def docs_ship_config = Ships::Config.current

  def docs_hours(seconds)
    value = seconds / 3600.0
    text = (value % 1).zero? ? value.to_i.to_s : value.round(2).to_s
    "#{text} #{value == 1 ? 'hour' : 'hours'}"
  end

  def docs_percent(basis_points)
    value = basis_points / 100.0
    (value % 1).zero? ? "#{value.to_i}%" : "#{value}%"
  end

  def docs_deflated_rate = docs_game.coins_per_hour * docs_game.deflation_multiplier_milli / 1000.0

  def docs_date(date) = date.strftime("%B %-d, %Y")
end
