# Read-only list of referral sources backed by config/referrals.yml.
class Referral < Data.define(:slug, :name)
  FORMAT = /\A[a-z0-9_-]{1,32}\z/

  def self.all
    @all ||= Rails.application.config_for(:referrals)[:referrals].map { |attrs| new(**attrs) }.freeze
  end

  def self.find(slug) = all.find { |referral| referral.slug == slug.to_s }
end
