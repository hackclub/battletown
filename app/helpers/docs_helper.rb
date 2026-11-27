# Numbers the /docs page quotes, read from the same config the game uses, so the page stays true when a value is tuned.
module DocsHelper
  Page = Data.define(:slug, :title, :lead, :sections)

  # The docs, in reading order. `sections` are [id, title, [children]]; each id is a heading on that page (landing links use them).
  PAGES = [
    Page.new("start", "Start here", "Battletown is a Hack Club You Ship We Ship program. Build projects, take down a weekly boss with the community and earn prizes.",
             [ [ "how-it-works", "How it works", [] ], [ "what-you-need", "What you need", [] ], [ "sign-up", "Signing up", [] ], [ "eligibility", "Who can join", [] ] ]),
    Page.new("hours", "Hackatime and hours", "How your coding time is counted, and the rules for it.",
             [ [ "hackatime", "Hackatime", [] ], [ "projects", "Projects", [] ], [ "coding-time", "What counts as coding time", [] ], [ "honesty", "Honesty", [] ] ]),
    Page.new("ships", "Ships", "What a ship needs, and what happens when a reviewer looks at it.",
             [ [ "ships", "How a ship works", [] ], [ "valid-ship", "What a valid ship is", [] ], [ "review", "When a ship is sent back", [] ] ]),
    Page.new("coins", "Coins and streaks", "How approved hours turn into coins, and what a streak adds.",
             [ [ "coins", "Earning coins", [] ], [ "streaks", "Streaks and the freeze", [] ] ]),
    Page.new("bosses", "Bosses and damage", "How the weekly boss takes damage.",
             [ [ "bosses", "How a boss works", [] ] ]),
    Page.new("shop", "Shop and fulfillment", "Spending coins, and how prizes and stickers reach you.",
             [ [ "shop", "The shop", [] ],
               [ "fulfillment", "Fulfillment", [ [ "ordering", "Ordering and addresses" ], [ "order-status", "Order status" ], [ "duties", "Import duties and customs" ] ] ],
               [ "legal", "Terms, privacy and security", [] ] ])
  ].freeze
  SLUGS = PAGES.map(&:slug).freeze

  def docs_page_path(page) = page.slug == "start" ? docs_path : docs_section_path(page.slug)

  def docs_previous(page)
    index = PAGES.index(page)
    PAGES[index - 1] if index.positive?
  end

  def docs_next(page) = PAGES[PAGES.index(page) + 1]

  def docs_game = Game::Config.current

  def docs_ship_config = Ships::Config.current

  def docs_hours(seconds)
    value = seconds / 3600.0
    text = (value % 1).zero? ? value.to_i.to_s : value.round(2).to_s
    "#{text} #{value == 1 ? 'hour' : 'hours'}"
  end

  def docs_percent(basis_points)
    value = basis_points / 100.0
    (value % 1).zero? ? "#{value.to_i}%" : "#{value}%"
  end

  def docs_deflated_rate = docs_game.coins_per_hour * docs_game.deflation_multiplier_milli / 1000.0

  def docs_date(date) = date.strftime("%B %-d, %Y")
end
