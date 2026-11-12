# Limit/offset paging for the staff lists (users, audit). Give it the total row count and the raw `page` param; it clamps the
# page into 1..pages, so a missing, negative, huge or non-numeric page never builds a silly OFFSET.
class AdminPager
  PER_PAGE = 50

  attr_reader :total, :page, :per

  def initialize(total:, page:, per: PER_PAGE)
    @total = total.to_i
    @per = per
    @page = [ [ parse(page), 1 ].max, pages ].min
  end

  def pages = [ (total.to_f / per).ceil, 1 ].max

  def offset = (page - 1) * per

  def first? = page == 1

  def last? = page == pages

  # "1 to 50 of 120"; empty list: "0 of 0".
  def range_text
    return "0 of 0" if total.zero?

    "#{offset + 1} to #{[ offset + per, total ].min} of #{total}"
  end

  def apply(scope) = scope.limit(per).offset(offset)

  private

  def parse(raw)
    text = raw.to_s
    text.match?(/\A\d{1,9}\z/) ? text.to_i : 1
  end
end
