module TeamsHelper
  # "5" for 500 basis points, "2.5" for 250.
  def team_bonus_percent_text(config = Teams::Config.current) = format("%g", config.bonus_bps / 100.0)

  # What a crewmate sees of someone: their display name and nothing else.
  def crew_member_name(user) = user.display_name.presence || "A Battletown member"

  def crew_time(time) = time.utc.strftime("%-d %b %H:%M UTC")

  def crew_coins(amount) = "#{number_with_delimiter(amount)} #{amount == 1 ? 'coin' : 'coins'}"
end
