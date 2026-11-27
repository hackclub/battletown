module Onboarding
  # What a person has answered in the quiz so far. The three answers the account keeps (prize, project kind, daily pace) are read from the
  # subject (the signed-in user, or the session-backed draft); every other answer lives in the session under `onb` (never in the database:
  # no migration, see the list for the back end in the hand-off), together with `pos`, the furthest step reached. A multi answer is an array.
  # The session key is kept across sign-in (ApplicationController#sign_in) so the editor answer can prefill the Hackatime step.
  class Answers
    SESSION_KEY = :onb
    SUBJECT = { "prize" => :prize_key, "project" => :project_kind, "schedule" => :pace_minutes }.freeze

    def initialize(session, subject)
      @session = session
      @subject = subject
    end

    def [](key)
      key = key.to_s
      return @subject.public_send(SUBJECT.fetch(key))&.to_s.presence if SUBJECT.key?(key)

      store[key]
    end

    def multi(key) = Array(self[key])

    def []=(key, value)
      @session[SESSION_KEY] = store.merge(key.to_s => value)
    end

    def pos = store["pos"]

    def pos=(key)
      self["pos"] = key
    end

    def prize = Prize.find(@subject.prize_key_in_database.presence || @subject.prize_key)

    # A picked project kind that has follow-up questions (everything but "Not sure yet").
    def kind = @subject.project_kind.presence
    def specific_kind? = kind.present? && kind != "undecided"
    def pace_minutes = @subject.pace_minutes

    private

    def store = @session[SESSION_KEY].is_a?(Hash) ? @session[SESSION_KEY] : {}
  end
end
