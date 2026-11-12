module Ships
  # The teen takes their ship back (a draft or a submitted one that is still waiting). Under `ship.with_lock` with the
  # status checked again, so it cannot race a reviewer's decision: whichever gets the lock first wins. A withdrawn
  # ship gives its window back, so the same hours go into the next ship.
  module Withdraw
    module_function

    # true when the ship was withdrawn now; false when it was already decided (approved or rejected) or withdrawn.
    def call(ship:)
      withdrawn = false
      ship.with_lock do
        next unless ship.open?

        ship.update!(status: "withdrawn")
        withdrawn = true
      end
      withdrawn
    end
  end
end
