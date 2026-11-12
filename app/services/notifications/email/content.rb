module Notifications
  module Email
    # The facts a template needs for one outbox row, built at send time (nothing is stored). Same rule as the Slack text
    # (Message): nil means "do not send", the thing the email is about is gone or no longer true (a ship that is not in
    # the expected state). Values are plain, one line and shortened; the templates escape them for HTML.
    module Content
      module_function

      def build(row, user)
        case row.kind
        when "ship_approved" then ship_approved(row, user)
        when "ship_rejected" then ship_rejected(row, user)
        when "returning_nudge" then returning_nudge(row, user)
        end
      end

      # The same test as the Slack nudge (Message): only while the returning flag is on, the idle period it was queued for is
      # still the current one and the person has not already coded today. Its facts (the boost length, the dashboard link)
      # are the Slack message's own.
      def returning_nudge(row, user)
        Message.values_for(row, user)&.slice(:boost_days, :link)
      end

      def ship_approved(row, user)
        ship = user.ships.find_by(id: row.subject_id, status: "approved")
        return nil unless ship

        { project: Message.short(ship.project.name), hours: Message.hours_text(ship.approved_seconds),
          coins: ship.coin_breakdown[:total], locked: !user.verification_verified?, verify_url: ShopHelper::VERIFY_URL,
          link: Links.ship(ship) }
      end

      def ship_rejected(row, user)
        ship = user.ships.find_by(id: row.subject_id, status: "rejected")
        return nil unless ship

        { project: Message.short(ship.project.name), reason: Message.sentence(ship.rejection_reason), link: Links.fix_ship(ship) }
      end
    end
  end
end
