module Nps
  # The Net Promoter Score maths, for the staff page. Promoters score 9 or 10, detractors 0 to 6, passives 7 or 8.
  # NPS = (promoters - detractors) / responses, as a percentage rounded to a whole number (halves away from zero),
  # so it runs from -100 to 100. With no responses there is no NPS (nil), never zero.
  module Stats
    TREND_DAYS = 14
    Tally = Data.define(:promoters, :passives, :detractors) do
      def responses = promoters + passives + detractors

      # Whole-number percentage, or nil when nobody answered.
      def nps
        return nil if responses.zero?

        (Rational((promoters - detractors) * 100, responses)).round
      end
    end
    Day = Data.define(:date, :tally)

    module_function

    def tally(scores)
      scores = scores.to_a
      Tally.new(promoters: scores.count { |score| score >= 9 }, passives: scores.count { |score| score.between?(7, 8) },
                detractors: scores.count { |score| score <= 6 })
    end

    def overall(scope = NpsResponse.all) = tally(scope.pluck(:score))

    # One Day per UTC date for the last TREND_DAYS days, newest last, empty days included.
    def trend(now: Time.current, scope: NpsResponse.all)
      today = now.utc.to_date
      from = today - (TREND_DAYS - 1)
      scores = scope.where(answered_at: from.beginning_of_day.utc..).pluck(:answered_at, :score).group_by { |time, _| time.utc.to_date }
      (from..today).map { |date| Day.new(date: date, tally: tally((scores[date] || []).map(&:last))) }
    end
  end
end
