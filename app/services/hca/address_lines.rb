module Hca
  # The ways an address is written out for a person, shared by Hca::Address (the dropdown preview) and OrderAddress (the buyer's
  # order page and the staff reveal). It needs `recipient_name line_1 line_2 city state postal_code country phone_number`.
  module AddressLines
    # In postal order: name, street, second street line, "city, region, postcode", country code. No phone.
    def lines
      [ recipient_name, line_1, line_2, [ city, state, postal_code ].compact_blank.join(", ").presence, country ].compact_blank
    end

    # The street line, the city and the country: enough to recognise an address, not enough to post to it.
    def masked_lines = [ line_1, city, country ].compact_blank

    def city_and_country = [ city, country ].compact_blank.join(", ")

    # "ends in 1234": enough to recognise the number, not enough to dial it.
    def masked_phone
      digits = phone_number.to_s.gsub(/\D/, "")
      digits.length >= 4 ? "ends in #{digits.last(4)}" : nil
    end
  end
end
