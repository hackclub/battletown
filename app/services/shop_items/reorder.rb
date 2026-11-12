module ShopItems
  # Moves one item a place up or down among the items that are shown with it (all the active ones, or all the archived ones),
  # in a single transaction under row locks, so two admins pressing the buttons at once cannot leave two items in one place.
  # Positions of that list are renumbered 1..n on every move, so ties from earlier edits are cleaned up as well.
  #
  #   ShopItems::Reorder.call(key: "tshirt", direction: "up")  # => true when it moved, false at the end of the list
  class Reorder
    DIRECTIONS = %w[up down].freeze

    def self.call(...) = new(...).call

    def initialize(key:, direction:)
      @key = key.to_s
      @direction = direction.to_s
    end

    def call
      raise ArgumentError, "direction must be up or down" unless DIRECTIONS.include?(@direction)

      moved = false
      ShopItem.transaction do
        target = ShopItem.without_content.find_by!(key: @key)
        list = ShopItem.without_content.where(active: target.active).in_order.lock.to_a
        index = list.index { |item| item.id == target.id }
        neighbour = @direction == "up" ? index - 1 : index + 1
        if neighbour.between?(0, list.size - 1)
          list[index], list[neighbour] = list[neighbour], list[index]
          moved = true
        end
        renumber(list)
      end
      Prize.reload!
      moved
    end

    private

    # Only rows whose position changes are written, and each bumps lock_version so a form opened before the move is stale.
    def renumber(list)
      list.each_with_index do |item, index|
        next if item.position == index + 1

        ShopItem.where(id: item.id).update_all([ "position = ?, lock_version = lock_version + 1, updated_at = ?", index + 1, Time.current ])
      end
    end
  end
end
