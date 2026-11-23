# Counts for the "N others picked this too" pages in onboarding. Only totals, never anyone's details. Briefly cached
# so a busy launch doesn't count the users table on every page view.
module OnboardingProof
  # Below this many other people a number would be embarrassing, so the page says "be one of the first" instead.
  MIN_OTHERS = 5
  CACHE_TTL = 5.minutes

  module_function

  def prize_count(key) = cached("prize/#{key}") { User.where(prize_key: key).count }

  def project_kind_count(kind) = cached("kind/#{kind}") { User.where(project_kind: kind).count }

  def cached(key, &) = Rails.cache.fetch("onboarding_proof/#{key}", expires_in: CACHE_TTL, &)
end
