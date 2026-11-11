# Derives a time zone from the address Hack Club Auth returns, so onboarding can default `users.time_zone`.
#
# PRIVACY: the address is read in memory only and is never stored, logged or returned. The only output is
# a time zone name. Callers must not keep the input around either.
#
# Input shapes accepted (string or symbol keys, plain Hashes or Hashie/OmniAuth mashes):
#   * the OIDC claims hash, with an `address` Hash (OIDC standard: street_address, locality, region,
#     postal_code, country) and/or an `addresses` Array of such Hashes (the one flagged primary wins, else
#     the first) and/or a `primary_address` Hash;
#   * a bare address Hash.
# Country may be an ISO 3166-1 alpha-2 code (what Hack Club Auth documents) or a common country name / alpha-3.
# Region may be a code or a full name; see config/address_time_zones.yml for the table and its known limits.
#
# `call` returns an IANA name or nil. `zone_name` returns the ActiveSupport::TimeZone name that the schedule
# step's select uses (and that User validates), or nil. Neither ever raises.
class AddressTimeZone
  REGIONS = YAML.safe_load_file(Rails.root.join("config/address_time_zones.yml")).freeze
  REGION_KEYS = %w[region state province administrative_area state_province].freeze
  COUNTRY_KEYS = %w[country country_code country_code_alpha2].freeze
  MAX_FIELD_LENGTH = 100

  COUNTRY_ALIASES = {
    "usa" => "US", "u s" => "US", "u s a" => "US", "america" => "US", "united states of america" => "US",
    "uk" => "GB", "united kingdom" => "GB", "great britain" => "GB", "britain" => "GB", "england" => "GB",
    "scotland" => "GB", "wales" => "GB", "northern ireland" => "GB",
    "can" => "CA", "gbr" => "GB", "aus" => "AU", "bra" => "BR", "brasil" => "BR", "mex" => "MX", "mexico" => "MX",
    "deu" => "DE", "fra" => "FR", "jpn" => "JP", "ind" => "IN", "irl" => "IE", "nzl" => "NZ", "esp" => "ES",
    "ita" => "IT", "nld" => "NL", "holland" => "NL", "swe" => "SE", "nor" => "NO", "dnk" => "DK", "fin" => "FI",
    "pol" => "PL", "prt" => "PT", "che" => "CH", "aut" => "AT", "bel" => "BE", "sgp" => "SG", "zaf" => "ZA",
    "kor" => "KR", "south korea" => "KR", "korea" => "KR", "chn" => "CN", "rus" => "RU", "russia" => "RU",
    "czech republic" => "CZ", "czechia" => "CZ", "turkey" => "TR", "turkiye" => "TR", "uae" => "AE",
    "hong kong" => "HK", "taiwan" => "TW", "vietnam" => "VN", "philippines" => "PH", "arg" => "AR", "col" => "CO"
  }.freeze

  # Offsets (seconds) at fixed instants across 2026 identify a zone's rules without caring about its name.
  SAMPLE_TIMES = (1..12).flat_map { |month| [ Time.utc(2026, month, 1), Time.utc(2026, month, 15) ] }.freeze

  class << self
    def call(source)
      address = pick_address(source)
      address && iana_for(address)
    rescue StandardError
      nil
    end

    def zone_name(source)
      iana = call(source)
      iana && rails_zone_name(iana)
    rescue StandardError
      nil
    end

    # The ActiveSupport::TimeZone name for an IANA identifier. Many identifiers (America/Toronto,
    # Europe/Luxembourg, ...) have no Rails name of their own, so fall back to a Rails zone with the same
    # UTC offsets all year, preferring one in the same country.
    def rails_zone_name(iana, country_identifiers = [])
      names = ActiveSupport::TimeZone::MAPPING.select { |_, identifier| identifier == iana }.keys
      city = iana.split("/").last
      direct = names.find { |name| name.tr(" ", "_") == city } || names.first
      return direct if direct

      equivalent = rails_zones_by_signature[signature(iana)].to_a
      equivalent.find { |name| country_identifiers.include?(ActiveSupport::TimeZone::MAPPING[name]) } || equivalent.first
    end

    private

    def pick_address(source)
      return unless source.respond_to?(:to_h)

      hash = source.to_h.deep_stringify_keys
      candidates = []
      candidates.concat(hashes(hash["primary_address"]).map { |address| address.merge("primary" => true) })
      candidates.concat(hashes(hash["addresses"]))
      candidates.concat(hashes(hash["address"]))
      candidates << hash if candidates.empty? && COUNTRY_KEYS.any? { |key| hash.key?(key) }
      candidates.find { |address| primary?(address) } || candidates.first
    end

    def hashes(value)
      case value
      when Hash then [ value ]
      when Array then value.grep(Hash)
      else []
      end
    end

    def primary?(address)
      [ address["primary"], address["is_primary"] ].any? { |flag| flag == true || flag.to_s.downcase == "true" }
    end

    def iana_for(address)
      country = country_code(value_for(address, COUNTRY_KEYS))
      return unless country

      regional(country, value_for(address, REGION_KEYS)) || uniform(TZInfo::Country.get(country).zone_identifiers)
    end

    def regional(country, region)
      key = normalise(region.to_s.sub(/\A#{country}-/i, ""))
      return if key.blank? || !REGIONS.key?(country)

      region_index(country)[key]
    end

    # A country is usable without a region when it has one zone, or all its zones share the same rules
    # (Germany's Europe/Busingen, Argentina's provinces, ...).
    def uniform(identifiers)
      return identifiers.first if identifiers.size == 1

      names = identifiers.map { |iana| rails_zone_name(iana, identifiers) }
      identifiers.first if names.none?(&:nil?) && names.uniq.size == 1
    end

    def value_for(address, keys)
      keys.each do |key|
        value = address[key]
        return value.to_s[0, MAX_FIELD_LENGTH] if value.is_a?(String) || value.is_a?(Symbol)
      end
      nil
    end

    def country_code(value)
      text = value.to_s.strip
      return if text.empty?

      upper = text.upcase
      return upper if upper.match?(/\A[A-Z]{2}\z/) && TZInfo::Country.all_codes.include?(upper)

      country_names[normalise(text)]
    end

    def normalise(text)
      ActiveSupport::Inflector.transliterate(text.to_s).downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def region_index(country)
      @region_index ||= {}
      @region_index[country] ||= REGIONS.fetch(country).each_with_object({}) do |(iana, labels), index|
        labels.each { |label| index[normalise(label)] = iana }
      end
    end

    def country_names
      @country_names ||= TZInfo::Country.all.to_h { |country| [ normalise(country.name), country.code ] }.merge(COUNTRY_ALIASES)
    end

    def rails_zones_by_signature
      @rails_zones_by_signature ||= ActiveSupport::TimeZone::MAPPING.keys.group_by do |name|
        signature(ActiveSupport::TimeZone::MAPPING.fetch(name))
      end
    end

    def signature(iana)
      zone = TZInfo::Timezone.get(iana)
      SAMPLE_TIMES.map { |time| zone.period_for_utc(time).observed_utc_offset }
    end
  end
end
