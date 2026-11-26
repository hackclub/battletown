# "Use my Slack name and picture" is something a player turns ON, never something that happens because they opted in to a visible
# profile (they are 13 to 18: the onboarding tick-box promises "never your Slack"). A new row, and a player with no row, now means off.
class DefaultSlackProfileChoiceOff < ActiveRecord::Migration[8.1]
  def change
    change_column_default :slack_profiles, :use_name, from: true, to: false
    change_column_default :slack_profiles, :use_picture, from: true, to: false
  end
end
