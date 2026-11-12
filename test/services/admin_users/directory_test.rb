require "test_helper"
require_relative "../../support/shop_helper"
require_relative "../../support/ships_test_support"

class AdminUsers::DirectoryTest < ActiveSupport::TestCase
  include ShopTestHelper
  include ShipsTestSupport

  setup do
    travel_to Time.utc(2026, 11, 12, 15)
    User.where.not(id: users(:onboarded).id).delete_all
    @ada = make("Ada Lovelace", email: "ada@example.test", slack_id: "U0ADA", hca_uid: "ident!ada", signed_up_on: Date.new(2026, 10, 1), onboarded: true,
                                verification_status: "verified", ysws_eligible: true, referral_source: "haven")
    @bob = make("bob the builder", email: "Bob@Example.test", slack_id: "U0BOB", hca_uid: "ident!bob", signed_up_on: Date.new(2026, 10, 15), onboarded: false)
    @cy = make("Cy 100%_off", email: "cy@example.test", slack_id: "U0CY", hca_uid: "ident!cy", signed_up_on: Date.new(2026, 11, 1), onboarded: true,
                              verification_status: "pending")
    @nameless = make(nil, email: nil, slack_id: nil, hca_uid: "ident!nameless", signed_up_on: Date.new(2026, 11, 5), onboarded: false, referral_source: "stardance")
  end

  def make(name, email:, slack_id:, hca_uid:, signed_up_on:, onboarded: false, verification_status: "needs_submission", ysws_eligible: false, referral_source: nil)
    user = User.create!(hca_uid: hca_uid, display_name: name, email: email, slack_id: slack_id, time_zone: "UTC", referral_source: referral_source)
    user.update_columns(signed_up_on: signed_up_on, created_at: signed_up_on.in_time_zone("UTC") + 12.hours, verification_status: verification_status,
                        ysws_eligible: ysws_eligible, onboarded_at: (Time.utc(2026, 11, 2) if onboarded), onboarding_step: (4 if onboarded) || 0)
    user
  end

  def names(params = {}) = AdminUsers::Directory.call(params).rows.map { |row| row.display_name || "(none)" }

  test "lists everyone, newest sign-up first by default, with no email, Slack id or Hack Club Auth id in a row" do
    result = AdminUsers::Directory.call({})
    assert_equal [ "(none)", "Cy 100%_off", "bob the builder", "Ada Lovelace", users(:onboarded).display_name ], result.rows.map { |row| row.display_name || "(none)" }
    assert_equal %i[id display_name verification_status ysws_eligible onboarded signed_up_on coins seconds last_coded hackatime], AdminUsers::Directory::Row.members
    assert_equal 5, result.totals.users
  end

  test "searches the display name as a case-insensitive substring and treats LIKE characters literally" do
    assert_equal [ "Ada Lovelace" ], names(q: "lovelace")
    assert_equal [ "Ada Lovelace" ], names(q: "ADA LOVE")
    assert_equal [ "bob the builder" ], names(q: "the build")
    assert_equal [ "Cy 100%_off" ], names(q: "100%_off")
    assert_equal [ "Cy 100%_off" ], names(q: "%"), "a lone % is a literal percent sign, not a wildcard"
    assert_equal [ "Cy 100%_off" ], names(q: "_off")
    assert_empty names(q: "zzz")
    assert_equal 5, AdminUsers::Directory.call(q: "   ").totals.users, "a blank search is no search"
  end

  test "searches Slack id and Hack Club Auth id exactly, and email exactly without regard to case" do
    assert_equal [ "Ada Lovelace" ], names(by: "slack_id", q: "U0ADA")
    assert_empty names(by: "slack_id", q: "U0AD"), "not a prefix match"
    assert_empty names(by: "slack_id", q: "u0ada"), "as typed"
    assert_equal [ "bob the builder" ], names(by: "hca_uid", q: "ident!bob")
    assert_empty names(by: "hca_uid", q: "ident!bo")
    assert_equal [ "Ada Lovelace" ], names(by: "email", q: "ada@example.test")
    assert_equal [ "Ada Lovelace" ], names(by: "email", q: "  ADA@Example.Test ")
    assert_equal [ "bob the builder" ], names(by: "email", q: "bob@example.test")
    assert_empty names(by: "email", q: "ada@example"), "an email must match completely"
    assert_empty names(by: "email", q: "example.test")
    assert_empty names(by: "email", q: "%@example.test")
  end

  test "hostile and huge search text is just text" do
    [ "'; DROP TABLE users; --", "\" OR 1=1 --", "x' OR '1'='1", "\\", "%%%%", "a" * 5000, "\u0000", "ada\u0000", "💥" * 400, "😀", "\n\r\t" ].each do |text|
      %w[name slack_id hca_uid email].each do |by|
        assert_nothing_raised { AdminUsers::Directory.call(by: by, q: text) }
      end
    end
    assert_equal 5, User.count
    assert_empty names(q: "x' OR '1'='1")
    assert_empty names(by: "email", q: "a" * 5000)
    assert_equal [ "Ada Lovelace" ], names(q: "ada\u0000"), "NUL bytes are dropped, not sent to the database"
    assert_equal 5, AdminUsers::Directory.call(q: nil, by: [ "x" ], sort: { a: 1 }, page: [ 1 ], onboarded: [ "yes" ]).totals.users
    assert_equal 5, AdminUsers::Directory.call(q: { a: "b" }).totals.users
  end

  test "an unknown search field falls back to the display name" do
    assert_equal [ "Ada Lovelace" ], names(by: "password", q: "ada")
  end

  test "filters: onboarded, verified, eligible, Hackatime, referral source, signed-up range" do
    HackatimeConnection.create!(user: @ada, hackatime_uid: "77", access_token: "dummy-token-1", scopes: "profile read", connected_at: Time.current)
    assert_equal [ "Cy 100%_off", "Ada Lovelace", users(:onboarded).display_name ].sort, names(onboarded: "yes").sort
    assert_equal [ "(none)", "bob the builder" ].sort, names(onboarded: "no").sort
    assert_equal [ "Ada Lovelace" ], names(verified: "yes")
    assert_equal 4, AdminUsers::Directory.call(verified: "no").totals.users
    assert_equal [ "Ada Lovelace" ], names(eligible: "yes")
    assert_equal 4, AdminUsers::Directory.call(eligible: "no").totals.users
    assert_equal [ "Ada Lovelace" ], names(hackatime: "yes")
    assert_equal 4, AdminUsers::Directory.call(hackatime: "no").totals.users
    assert_equal [ "Ada Lovelace" ], names(referral: "haven")
    assert_equal [ "(none)" ], names(referral: "stardance")
    assert_equal 3, AdminUsers::Directory.call(referral: "none").totals.users
    assert_empty names(referral: "no-such-source")
    assert_equal [ "(none)", "Cy 100%_off" ].sort, names(from: "2026-11-01", to: "2026-11-09").sort
    assert_equal [ "bob the builder" ], names(from: "2026-10-10", to: "2026-10-20")
    assert_equal [ "bob the builder" ], names(from: "2026-10-15", to: "2026-10-15"), "both ends are inclusive"
  end

  test "filters combine, and junk filter values are ignored" do
    assert_equal [ "Ada Lovelace" ], names(onboarded: "yes", verified: "yes", referral: "haven")
    assert_empty names(onboarded: "no", verified: "yes")
    [ "maybe", "YES", "1", "true", "'; --", "x" * 500 ].each { |junk| assert_equal 5, AdminUsers::Directory.call(onboarded: junk, verified: junk, eligible: junk, hackatime: junk).totals.users }
    assert_equal 5, AdminUsers::Directory.call(from: "not a date", to: "2026-13-45", referral: "Bad Slug!").totals.users
    assert_equal 5, AdminUsers::Directory.call(from: "0001-01-01", to: "9999-12-31").totals.users, "absurd years are ignored"
  end

  test "sorting: name, oldest, coins, hours and last coded, with ties broken by id" do
    give_coins(@bob, 50)
    give_coins(@ada, 20)
    code(@cy, Date.new(2026, 11, 10), 3600)
    code(@ada, Date.new(2026, 11, 11), 1800)
    code(@ada, Date.new(2026, 11, 5), 1800)

    assert_equal [ "(none)", "Ada Lovelace", "bob the builder", "Cy 100%_off" ], names(sort: "name").first(4)
    assert_equal users(:onboarded).display_name, names(sort: "oldest").first
    assert_equal [ "bob the builder", "Ada Lovelace" ], names(sort: "coins").first(2)
    assert_equal [ "Cy 100%_off", "Ada Lovelace" ], names(sort: "hours").first(2)
    assert_equal [ "Ada Lovelace", "Cy 100%_off" ], names(sort: "last_coded").first(2)
    assert_equal names(sort: "newest"), names(sort: "'; DROP TABLE users; --"), "an unknown sort is the default"
  end

  test "each row carries the coin balance, counted hours, last coded date and Hackatime state" do
    give_coins(@ada, 75)
    Coins::Ledger.debit(user: @ada, amount: 5, kind: "adjustment", idempotency_key: "d")
    code(@ada, Date.new(2026, 11, 11), 1800)
    code(@ada, Date.new(2026, 11, 11), 900)
    code(@ada, Date.new(2026, 11, 3), 600)
    HourEntry.create!(user: @ada, local_date: Date.new(2026, 11, 3), seconds: -2000, source: "adjustment", note: "over-correct", idempotency_key: "neg")
    code(@ada, Date.new(2026, 9, 1), 7200) # before sign-up (2026-10-01): not counted
    HackatimeConnection.create!(user: @ada, hackatime_uid: "77", access_token: "dummy-token-1", scopes: "profile read", connected_at: Time.current)

    row = AdminUsers::Directory.call(q: "ada").rows.sole
    assert_equal 70, row.coins
    assert_equal 2700, row.seconds, "a day's net is floored at zero and days before sign-up are left out"
    assert_equal Date.new(2026, 11, 11), row.last_coded
    assert_equal true, row.hackatime
    assert_equal [ 0, 0, nil, false ], AdminUsers::Directory.call(q: "bob the").rows.sole.then { |other| [ other.coins, other.seconds, other.last_coded, other.hackatime ] }
  end

  test "header totals follow the filters, not the page" do
    totals = AdminUsers::Directory.call(onboarded: "yes").totals
    assert_equal [ 3, 3 ], [ totals.users, totals.onboarded ]
    full = AdminUsers::Directory.call({}).totals
    assert_equal [ 5, 3, 1, 1, 0 ], [ full.users, full.onboarded, full.verified, full.eligible, full.hackatime ]
  end

  test "pages of 50 with clamped page numbers" do
    55.times { |i| User.create!(hca_uid: "ident!bulk-#{i}", display_name: "Bulk #{i}", time_zone: "UTC") }
    assert_equal 60, AdminUsers::Directory.call({}).totals.users
    first = AdminUsers::Directory.call({})
    assert_equal [ 50, 1, 2 ], [ first.rows.size, first.pager.page, first.pager.pages ]
    second = AdminUsers::Directory.call(page: "2")
    assert_equal [ 10, 2 ], [ second.rows.size, second.pager.page ]
    assert_equal (first.rows + second.rows).map(&:id).sort, User.pluck(:id).sort, "every person on exactly one page"
    [ "0", "-4", "abc", "", "99999999999999999999", "3", "2.5", [ 2 ], { a: 1 } ].each do |page|
      result = AdminUsers::Directory.call(page: page)
      assert_includes [ 1, 2 ], result.pager.page, page.inspect
      assert_operator result.rows.size, :>, 0
    end
    assert_equal 2, AdminUsers::Directory.call(page: "3").pager.page
    assert_equal [ 0, 1, "0 of 0" ], AdminUsers::Directory.call(q: "nobody-like-this").then { |empty| [ empty.rows.size, empty.pager.page, empty.pager.range_text ] }
  end

  test "exactly 50 people is one page and 51 is two" do
    45.times { |i| User.create!(hca_uid: "ident!fill-#{i}", time_zone: "UTC") }
    assert_equal [ 50, 1 ], AdminUsers::Directory.call({}).then { |result| [ result.rows.size, result.pager.pages ] }
    User.create!(hca_uid: "ident!fill-extra", time_zone: "UTC")
    assert_equal [ 50, 2 ], AdminUsers::Directory.call({}).then { |result| [ result.rows.size, result.pager.pages ] }
    assert_equal 1, AdminUsers::Directory.call(page: 2).rows.size
  end

  def count_queries(&block)
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  test "the number of queries does not depend on how many people are listed" do
    queries = ->(params = {}) { count_queries { AdminUsers::Directory.call(params).rows.each { |row| row.display_name } } }
    queries.call # warm the schema cache
    small = queries.call
    50.times do |i|
      user = User.create!(hca_uid: "ident!many-#{i}", display_name: "Many #{i}", time_zone: "UTC")
      give_coins(user, 5)
      code(user, Date.new(2026, 11, 10), 600)
      HackatimeConnection.create!(user: user, hackatime_uid: (1000 + i).to_s, access_token: "dummy-token-#{i}", scopes: "profile read", connected_at: Time.current)
    end
    assert_equal small, queries.call, "the list is a fixed number of queries"
    assert_operator queries.call(sort: "coins", q: "many"), :<=, 4
    assert_operator small, :<=, 4
  end
end
