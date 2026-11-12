module ShopHelper
  VERIFY_URL = "https://auth.hackclub.com".freeze

  # "1 coin", "30 coins", "1,200 coins".
  def coins_text(amount) = "#{number_with_delimiter(amount)} #{amount == 1 ? 'coin' : 'coins'}"

  # A price: "Free" for zero.
  def price_text(amount) = amount.zero? ? "Free" : coins_text(amount)

  # Orders carry a calendar date in the person's own zone (UTC when unset).
  def order_date(time, user = current_user)
    zone = ActiveSupport::TimeZone[user.time_zone.to_s] || ActiveSupport::TimeZone["UTC"]
    time.in_time_zone(zone).strftime("%-d %b %Y")
  end

  def verification_label(user) = user.verification_status.tr("_", " ")

  # The eligibility gate's two extra states (flag `eligibility_gate`): the same words wherever they show. The reason a
  # person is not eligible is never given, here or anywhere.
  def eligibility_text(state)
    case state
    when :not_eligible then "#{Shop::NotEligible::TEXT} #{Eligibility::Config.current.help_line}"
    when :stale then Shop::NeedsRecheck::TEXT
    end
  end

  # What a locked shop button says, per state.
  def shop_locked_label(state)
    { not_eligible: "Not available yet", stale: "Sign in to refresh" }.fetch(state, "Locked until you verify")
  end

  # Staff pages: "verified", plus (flag on) whether Hack Club Auth said they are YSWS eligible and whether the copy is old.
  def staff_identity_text(user)
    text = verification_label(user)
    return text unless Features.enabled?(:eligibility_gate, user)

    text += ", YSWS eligible: #{user.ysws_eligible? ? 'yes' : 'no'}"
    text += ", needs re-check" if user.verification_verified? && user.verification_stale?
    text
  end
end
