module MerchTrack
  # Which item a boss week earns: the Nth boss (oldest first) earns the Nth item of `week_items`. Past the end of the
  # list it depends on `after_last_week` (nothing, or the last item again).
  module Track
    # One row of the track page: the week's number, its boss (nil while that boss has not been created yet) and item.
    Week = Data.define(:number, :boss, :item)

    module_function

    # 0 for the first boss ever, 1 for the next, and so on.
    def index_for(boss) = Boss.where(starts_on: ...boss.starts_on).count

    def item_for(boss, config: Config.current) = config.item_for(index_for(boss))

    # Everything the track page lists: one row per boss week with its item, plus a row (boss nil) for each of the first
    # `week_items` weeks that has no boss yet, so the whole track is visible from the start.
    def weeks(config: Config.current)
      bosses = Boss.chronological.to_a
      rows = bosses.each_with_index.filter_map do |boss, index|
        item = config.item_for(index)
        Week.new(number: index + 1, boss: boss, item: item) if item
      end
      (bosses.size...config.items.size).each { |index| rows << Week.new(number: index + 1, boss: nil, item: config.items[index]) }
      rows
    end
  end
end
