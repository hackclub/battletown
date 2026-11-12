module Plinko
  # Plinko weeks run Friday to Thursday, like the weekly boss and the admin metrics (Date#wday: Friday = 5).
  module Week
    START_WDAY = 5

    module_function

    def range(date)
      starts_on = date - ((date.wday - START_WDAY) % 7)
      starts_on..(starts_on + 6)
    end
  end
end
