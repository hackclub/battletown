# An answer to "How did you hear about us?": the generic sources in config/referral_sources.yml plus the
# Hack Club programs from config/referrals.yml (which also drive the /<slug> attribution links; the generic keys do not).
class ReferralSource < Data.define(:key, :name)
  def self.config = Rails.application.config_for(:referral_sources)

  # Generic sources, in display order, without "Something else".
  def self.generic
    @generic ||= config[:sources].map { |attrs| new(**attrs) }.freeze
  end

  # Hack Club programs we already attribute, e.g. Haven.
  def self.programs
    @programs ||= Referral.all.map { |referral| new(key: referral.slug, name: referral.name) }.freeze
  end

  def self.other = @other ||= new(**config[:other])

  # Every valid stored value: generic sources, then programs, then "Something else".
  def self.all = @all ||= [ *generic, *programs, other ].freeze

  def self.keys = all.map(&:key)

  def self.find(key) = all.find { |source| source.key == key.to_s }
end
