module Analytics
  # The allowlist, read from config/analytics.yml: which events exist and which properties each may carry, with the type of every property.
  # `clean` is the only way a property reaches the database: anything not declared is refused (Invalid), and no property is ever a free string.
  module Events
    class Invalid < StandardError; end

    MAX_PROPS = 8
    # The database check is octet_length(props::text) <= 400; jsonb's text form puts a space after each colon and comma.
    MAX_PROPS_BYTES = 400
    KEY_FORMAT = /\A[a-z0-9_]{1,60}\z/
    NAME_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
    MAX_DEDUPE_KEY = 60

    class << self
      def config = @config ||= Rails.application.config_for(:analytics)

      def definitions = config.fetch(:events)

      def names = definitions.keys.map(&:to_s)

      def known?(name) = definitions.key?(name.to_s.to_sym)

      # Validates `props` against the event's declaration and returns the string-keyed hash to store. nil values are left out.
      def clean(name, props)
        definition = definitions[name.to_s.to_sym] or raise Invalid, "unknown analytics event #{name.to_s.first(40).inspect}"
        props = props.compact
        unknown = props.keys.map(&:to_sym) - definition.keys
        raise Invalid, "#{name}: unknown properties #{unknown.inspect}" if unknown.any?
        raise Invalid, "#{name}: more than #{MAX_PROPS} properties" if props.size > MAX_PROPS

        cleaned = props.to_h { |key, value| [ key.to_s, coerce(name, key, definition.fetch(key.to_sym), value) ] }
        raise Invalid, "#{name}: properties too big" if size_of(cleaned) > MAX_PROPS_BYTES

        cleaned
      end

      # The largest the stored text of `props` can be for an event, from the declaration alone (a test keeps it under the database check).
      def max_props_bytes(name)
        size_of(definitions.fetch(name.to_sym).to_h { |key, spec| [ key.to_s, widest(spec) ] })
      end

      private

      def coerce(name, key, spec, value)
        invalid = ->(why) { Invalid.new("#{name}.#{key}: #{why}") }
        case spec
        when "bool"
          [ true, false ].include?(value) ? value : raise(invalid.call("not a boolean"))
        else
          type, rule = spec.first
          case type
          when :int then coerce_int(value, rule) || raise(invalid.call("not a whole number in range"))
          when :enum then rule.find { |allowed| allowed.to_s == value.to_s && (allowed.is_a?(Integer) == value.is_a?(Integer)) } || raise(invalid.call("not an allowed value"))
          when :key then coerce_key(value, rule) || raise(invalid.call("not a catalogue key"))
          else raise invalid.call("undeclared type")
          end
        end
      end

      def coerce_int(value, range)
        value if value.is_a?(Integer) && value.between?(range[:min], range[:max])
      end

      def coerce_key(value, rule)
        return unless value.is_a?(String) || value.is_a?(Symbol)

        key = value.to_s
        return unless key.match?(KEY_FORMAT)
        return if rule == "referral" && Referral.find(key).nil?

        key
      end

      def size_of(hash) = hash.to_json.bytesize + (2 * hash.size)

      def widest(spec)
        return false if spec == "bool"

        type, rule = spec.first
        case type
        when :int then rule[:max]
        when :enum then rule.max_by { |value| value.to_s.length }
        else "x" * 60
        end
      end
    end
  end
end
