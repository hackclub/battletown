# The one shipping address of an order, copied from the person's Hack Club Auth account when the order was placed (or when they
# changed it, while the order was still requested or on hold). Every personal column is encrypted at rest with Active Record
# encryption (non-deterministic, so equal addresses look different in the table); only `country` (an ISO 3166-1 alpha-2 code, so
# staff can plan postage without opening anything), `hca_address_id` (which Hack Club Auth address it was) and `purge_after`
# are plain. Encrypted attributes are left out of #inspect and, with the filter list in config/initializers/filter_parameter_logging.rb,
# out of the logs.
#
# It lives as long as the parcel needs it and no longer: Orders::PurgeAddresses deletes it 30 days after the order is shipped or
# fulfilled (config `address_retention_days`), straight away when the order is cancelled or refunded, and the database
# deletes it with the order or the person (both foreign keys cascade). Staff see it only through Admin::OrderAddressesController
# (an audited reveal); nothing else reads the encrypted columns except the buyer's own order pages.
class OrderAddress < ApplicationRecord
  ENCRYPTED = %i[recipient_name line_1 line_2 city state postal_code phone_number].freeze
  LIMITS = Hca::Address::LIMITS

  belongs_to :order, inverse_of: :address
  belongs_to :user

  encrypts(*ENCRYPTED)

  validates :recipient_name, :line_1, :city, presence: true
  validates :country, format: { with: /\A[A-Z]{2}\z/ }
  validates :hca_address_id, length: { in: 1..80 }, allow_nil: true
  LIMITS.each { |field, max| validates field, length: { maximum: max } }
  validate :country_is_real
  validate :belongs_to_the_orders_owner

  # What the buyer and the label need, in postal order (no phone: ask for it with `phone_number`).
  def lines
    [ recipient_name, line_1, line_2, [ city, state, postal_code ].compact_blank.join(", ").presence, country ].compact_blank
  end

  # "ends in 1234": enough for the buyer to recognise the number, not enough to dial it.
  def masked_phone
    digits = phone_number.to_s.gsub(/\D/, "")
    digits.length >= 4 ? "ends in #{digits.last(4)}" : nil
  end

  # The shortest useful line for staff and lists: city and country only.
  def city_and_country = [ city, country ].compact_blank.join(", ")

  # The buyer's masked view: the street line, the city and the country.
  def masked_lines = [ line_1, city, country ].compact_blank

  # Copies a chosen Hack Club Auth address (Hca::Address) into a new or existing row. Returns the unsaved/updated record.
  def copy_from(hca_address)
    assign_attributes(recipient_name: hca_address.recipient_name, line_1: hca_address.line_1, line_2: hca_address.line_2, city: hca_address.city,
                      state: hca_address.state, postal_code: hca_address.postal_code, phone_number: hca_address.phone_number,
                      country: hca_address.country, hca_address_id: hca_address.id)
    self
  end

  private

  def country_is_real
    errors.add(:country, "is not a country code") if country.present? && !TZInfo::Country.all_codes.include?(country)
  end

  def belongs_to_the_orders_owner
    errors.add(:user, "must be the person who placed the order") if order && user_id != order.user_id
  end
end
