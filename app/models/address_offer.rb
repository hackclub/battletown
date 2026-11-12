# The list of addresses Hack Club Auth returned for a person at checkout, kept for a few minutes (config `address_offer_minutes`,
# 15) so they can pick one in a dropdown. It is the only place the whole list exists in this app: encrypted (Active Record
# encryption), one row per person and checkout (`draft_key` is the checkout's idempotency key, or "order-<id>" when changing the
# address of an order), and gone when the order is placed (the payload is emptied the moment it is used), when it expires, or when
# the person starts a new lookup (a new offer replaces every older one of theirs). `Orders::PurgeAddresses.purge_offers` deletes the
# rest; the database deletes them with the person.
#
# The browser is only ever shown, and only ever posts back, an address id (Hack Club Auth's, e.g. "addr_..."). The server looks
# that id up here, in the current person's own unexpired, unused offer; address text from a browser is never read.
class AddressOffer < ApplicationRecord
  DRAFT_FORMAT = /\A[A-Za-z0-9_-]{1,100}\z/

  belongs_to :user

  encrypts :payload

  validates :draft_key, format: { with: DRAFT_FORMAT }
  validates :expires_at, presence: true

  scope :live, -> { where(used_at: nil).where("expires_at > ?", Time.current) }
  scope :stale, ->(now = Time.current) { where("expires_at <= ? OR used_at IS NOT NULL", now) }

  # Replaces every offer this person has with one for `draft_key`. Also sweeps the stale ones of everybody (cheap, indexed).
  def self.store!(user:, draft_key:, result:, now: Time.current)
    payload = { addresses: result.addresses.map(&:to_stored), skipped: result.skipped }.to_json
    transaction do
      stale(now).delete_all
      where(user_id: user.id).delete_all
      create!(user: user, draft_key: draft_key, payload: payload, expires_at: now + Orders::Config.current.address_offer_minutes.minutes)
    end
  end

  # The person's unexpired, unused offer for this checkout, or nil.
  def self.live_for(user, draft_key)
    return nil unless draft_key.is_a?(String) && draft_key.match?(DRAFT_FORMAT)

    live.find_by(user_id: user.id, draft_key: draft_key)
  end

  # Was there an offer for this checkout that has since expired or been used? (To tell "ask again" from "never asked".)
  def self.expired_for?(user, draft_key)
    draft_key.is_a?(String) && where(user_id: user.id, draft_key: draft_key, used_at: nil).where("expires_at <= ?", Time.current).exists?
  end

  def addresses
    @addresses ||= Array(parsed["addresses"]).filter_map { |entry| Hca::Address.from_stored(entry) }
  end

  def skipped = parsed["skipped"].to_i

  def find_address(id) = id.is_a?(String) && id.present? ? addresses.find { |address| address.id == id } : nil

  # Marks the offer used and empties it: the list is not kept a minute longer than the order that used it.
  def use!(now: Time.current)
    update!(used_at: now, payload: { addresses: [], skipped: 0 }.to_json)
    @addresses = nil
    @parsed = nil
  end

  private

  def parsed
    @parsed ||= begin
      data = JSON.parse(payload.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end
  end
end
