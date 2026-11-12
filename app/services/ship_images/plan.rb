module ShipImages
  # What a ship form post asks to do with a ship's screenshots (flag `ship_screenshots`), worked out and checked BEFORE
  # the ship is saved, so a bad file never leaves a half-saved ship: build it, show `errors` if there are any, otherwise
  # `commit!` it inside the transaction that saves the ship (Ships::Submit's `after_save`).
  #
  # The form has one slot per position (1 to max_files). Params: `images[<position>][file]` (an upload),
  # `images[<position>][alt]` (optional text for screen readers) and `images[<position>][remove]` ("1" to remove it).
  #   - a file in a slot replaces what is there (a new slot is filled);
  #   - remove empties the slot; alt alone only changes the text;
  #   - a new ship made from a rejected one ("fix and ship again", `carry_from`) keeps that ship's screenshots in the
  #     slots the teen does not change or remove, copied (the bytes are already re-encoded).
  # Files are processed one at a time (ShipImages::Processor); only the small WebP results are held until commit.
  # Screenshots can be changed while the ship is a draft (or being made); once it is submitted or decided they are read-only.
  class Plan
    EDITABLE_STATUSES = %w[draft rejected].freeze
    Slot = Data.define(:position, :upload, :alt, :remove)
    Replacement = Data.define(:position, :processed, :alt)

    attr_reader :errors

    def self.build(params:, ship: nil, carry_from: nil, config: Config.current)
      new(params: params, ship: ship, carry_from: carry_from, config: config).tap(&:build)
    end

    def initialize(params:, ship:, carry_from:, config:)
      @params = indifferent(params)
      @ship = ship
      @carry_from = carry_from
      @config = config
      @errors = []
      @replacements = []
      @removals = []
      @alt_changes = {}
      @carried = []
    end

    def build
      slots = parse_slots
      return if slots.empty? && @carry_from.nil?

      touched = slots.select { |slot| slot.upload || slot.remove || slot.alt }
      if touched.any? && !editable?
        @errors << "Screenshots can't be changed once a ship has been submitted."
        return
      end

      slots.each { |slot| plan_slot(slot) }
      plan_carried(slots)
      check_duplicates
    ensure
      @errors.uniq!
    end

    def errors? = @errors.any?

    # True when committing would change anything.
    def changes? = [ @replacements, @removals, @alt_changes, @carried ].any?(&:present?)

    # Applies the plan to the saved `ship`. Call it inside the transaction that saved the ship.
    def commit!(ship)
      return unless changes?

      ShipImage.where(ship_id: ship.id, position: @removals + @replacements.map(&:position)).delete_all
      @replacements.each { |change| store(ship, change.position, change.processed, change.alt) }
      @alt_changes.each { |position, alt| ShipImage.where(ship_id: ship.id, position: position).update_all(alt: alt) }
      @carried.each { |position, alt| copy_carried(ship, position, alt) }
    end

    private

    def indifferent(params)
      hash = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
      hash.is_a?(Hash) ? hash.with_indifferent_access : {}
    end

    def editable? = @ship.nil? || EDITABLE_STATUSES.include?(@ship.status)

    def existing = @existing ||= (@ship&.persisted? ? @ship.images.index_by(&:position) : {})

    def carried_images = @carried_images ||= (@carry_from ? @carry_from.images.index_by(&:position) : {})

    def parse_slots
      return [] unless @params.respond_to?(:keys)

      @params.keys.filter_map do |key|
        position = Integer(key.to_s, 10, exception: false)
        raw = @params[key]
        unless position && position.between?(1, @config.max_files)
          @errors << "You can add up to #{@config.max_files} #{'screenshot'.pluralize(@config.max_files)}."
          next
        end
        next unless raw.respond_to?(:keys)

        upload = raw[:file]
        upload = nil if upload.respond_to?(:empty?) && upload.empty?
        alt = raw.key?(:alt) ? raw[:alt].to_s.squish.presence : nil
        Slot.new(position: position, upload: upload, alt: alt, remove: raw[:remove].to_s == "1")
      end.uniq(&:position).sort_by(&:position)
    end

    def plan_slot(slot)
      label = "Screenshot #{slot.position}"
      if slot.alt && slot.alt.length > ShipImage::ALT_MAX
        @errors << "#{label}: the description is too long (the limit is #{ShipImage::ALT_MAX} characters)."
        return
      end

      if slot.upload
        process(slot, label)
      elsif slot.remove
        @removals << slot.position if existing.key?(slot.position)
      elsif slot.alt && existing.key?(slot.position) && existing[slot.position].alt != slot.alt
        @alt_changes[slot.position] = slot.alt
      end
    end

    def process(slot, label)
      unless slot.upload.respond_to?(:tempfile)
        @errors << "#{label}: that wasn't a file we could read."
        return
      end

      processed = Processor.call(slot.upload, config: @config)
      @replacements << Replacement.new(position: slot.position, processed: processed, alt: slot.alt)
    rescue Rejected => error
      @errors << "#{label}: #{error.message}"
    end

    # A new ship made from a rejected one keeps the screenshots the teen left alone.
    def plan_carried(slots)
      return unless @carry_from && @ship.nil?

      by_position = slots.index_by(&:position)
      carried_images.each do |position, image|
        next if position > @config.max_files

        slot = by_position[position]
        next if slot&.upload || slot&.remove

        @carried << [ position, slot&.alt || image.alt ]
      end
    end

    def check_duplicates
      return if @errors.any?

      kept = existing.reject { |position, _| @removals.include?(position) || @replacements.any? { |change| change.position == position } }
      finals = kept.transform_values(&:sha256)
      carried_images.each { |position, image| finals[position] = image.sha256 if @carried.any? { |carried| carried.first == position } }
      @replacements.each { |change| finals[change.position] = change.processed.sha256 }

      finals.group_by { |_, sha| sha }.each_value do |same|
        next if same.size < 2

        positions = same.map(&:first).sort
        @errors << "Screenshot #{positions.last} is the same picture as screenshot #{positions.first}. Each one should be different."
      end
    end

    def store(ship, position, processed, alt)
      ShipImage.create!(ship: ship, user_id: ship.user_id, position: position, content: processed.content, width: processed.width,
                        height: processed.height, byte_size: processed.byte_size, sha256: processed.sha256, alt: alt)
    end

    # One at a time, so only one carried image's bytes are in memory.
    def copy_carried(ship, position, alt)
      source = ShipImage.find_by!(ship_id: @carry_from.id, position: position)
      store(ship, position, Processed.new(content: source.content, width: source.width, height: source.height, byte_size: source.byte_size, sha256: source.sha256), alt)
    end
  end
end
