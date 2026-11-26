# Where a Hack Club sign-in sends someone back to: the page they pressed "I've verified, refresh" on.
# The page name travels through the sign-in as a plain `return_to` param (OmniAuth hands it back to the callback), so it is
# untrusted. `path` only ever returns a same-site path of lowercase letters, digits, "-", "_" and single slashes under one of
# a few known sections, or nil. No scheme, host, "//", backslash, dot, query or fragment can get through, so it cannot
# become an open redirect.
module SignInReturn
  PARAM = "return_to"
  SECTIONS = %w[shop merch ships projects dashboard].freeze
  PATH = %r{\A/[a-z0-9_-]+(?:/[a-z0-9_-]+)*\z}
  MAX_LENGTH = 200

  module_function

  def path(value)
    return nil unless value.is_a?(String) && value.length <= MAX_LENGTH && value.match?(PATH)

    value if SECTIONS.include?(value.split("/")[1])
  end
end
