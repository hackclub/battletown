module SlackProfiles
  # The text of a Slack display name made safe to keep and to show. It is escaped on output as always (ERB), this is the second layer:
  #
  #  - Unicode normalised (NFC), control characters, line and paragraph separators, BIDI overrides, embeds and isolates (they can make
  #    text read backwards or hide what follows), zero-width and other invisible format characters, the byte-order mark and private
  #    use / unassigned code points are removed, and whitespace is squeezed to single spaces;
  #  - at most NAME_MAX characters (cut on a character, never inside one).
  #
  # `profile_name` is the stricter step for the player's chosen profile name (PublicProfile::NAME_FORMAT: letters, numbers, spaces and
  # . _ ' - only, nothing that reads as a web address): it keeps what is allowed and drops the rest, or returns nil when nothing
  # usable is left (an emoji-only name), so the caller leaves the current name alone.
  module Sanitizer
    NAME_MAX = SlackProfile::NAME_MAX
    # Cc control, Cf format (zero-width, BIDI marks and overrides, BOM, ...), Zl/Zp line and paragraph separators, Co private use, Cn unassigned.
    UNSAFE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cn}]/

    module_function

    # The display name to keep (nil when nothing printable is left).
    def display_name(raw)
      text = raw.to_s.dup.force_encoding(Encoding::UTF_8)
      return unless text.valid_encoding?

      text = text.unicode_normalize(:nfc).gsub(/[\t\n\r\f\v\u0085]/, " ").gsub(UNSAFE, "").gsub(/[[:space:]]+/, " ").strip
      text.first(NAME_MAX).strip.presence
    end

    # A name PublicProfile accepts, made from a sanitised display name, or nil.
    def profile_name(raw)
      text = display_name(raw)
      return if text.nil?

      text = text.gsub(/[^\p{L}\p{N} ._'\-]/, "").gsub(/\s+/, " ").sub(/\A[^\p{L}\p{N}]+/, "").strip
      text = text.delete(".") if text.match?(PublicProfile::NAME_LOOKS_LIKE_ADDRESS)
      text = text.first(PublicProfile::NAME_MAX).strip
      text if text.match?(PublicProfile::NAME_FORMAT)
    end
  end
end
