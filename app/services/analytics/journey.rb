module Analytics
  # The small reductions the visitor-journey events need (plans/analytics.md, WP2): what an onboarding answer becomes as an event property,
  # and where a Hackatime connection was started from. Everything returned is an enum value, a bucket, a bool or a catalogue key from
  # config/analytics.yml; never the idea, the times of day, the time zone or anything typed.
  module Journey
    class << self
      # `subject` is the signed-in user or the visitor's OnboardingDraft (the answers just saved). The age step has no property: only a teen
      # gets past it, and anyone else records onboarding_ineligible with no answer at all.
      def onboarding_props(step, subject)
        case step.to_s
        when "prize" then { prize_key: subject.prize_key }
        when "project" then { project_kind: subject.project_kind, has_idea: subject.project_idea.present? }
        when "schedule" then { days_count: subject.coding_day_names.size, pace_minutes: subject.pace_minutes }
        else {}
        end
      end

      # onboarding while the person is still onboarding, settings for someone who is in and pressed the button themselves, other for the
      # sign-in chain that sent an onboarded person on to Hackatime.
      def hackatime_from(user, chained:)
        if !user.onboarded? then "onboarding"
        elsif chained then "other"
        else "settings"
        end
      end
    end
  end
end
