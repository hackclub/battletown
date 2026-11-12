require "test_helper"
require "tempfile"

class Hackatime::CsvSourceTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @user.update_column(:slack_id, "U01ABCDEF")
    @files = []
  end

  teardown { @files.each(&:close!) }

  def csv(text)
    file = Tempfile.new([ "hours", ".csv" ])
    file.write(text)
    file.flush
    @files << file
    file.path
  end

  def source(text) = Hackatime::CsvSource.new(csv(text))

  test "reads days for a user matched by slack id" do
    src = source(<<~CSV)
      slack_id,date,seconds,project
      U01ABCDEF,2026-11-10,3600,my-game
      U01ABCDEF,2026-11-11,1200,
      U99ZZZZZZ,2026-11-10,500,other
    CSV

    days = src.daily_seconds(user: @user, from: nil, to: nil)
    assert_equal [ [ Date.new(2026, 11, 10), 3_600, "my-game" ], [ Date.new(2026, 11, 11), 1_200, nil ] ],
                 days.map { |day| [ day.date, day.seconds, day.project ] }
    assert_equal 3, src.row_count
    assert_equal 0, src.invalid_row_count
  end

  test "the project column is optional and quoted commas are fine" do
    src = source("slack_id,date,seconds\nU01ABCDEF,2026-11-10,60\n")
    assert_nil src.daily_seconds(user: @user, from: nil, to: nil).first.project

    src = source(%(slack_id,date,seconds,project\nU01ABCDEF,2026-11-10,60,"a, b"\n))
    assert_equal "a, b", src.daily_seconds(user: @user, from: nil, to: nil).first.project
  end

  test "from and to bound the days inclusively" do
    src = source("slack_id,date,seconds\nU01ABCDEF,2026-11-09,1\nU01ABCDEF,2026-11-10,2\nU01ABCDEF,2026-11-11,3\n")
    days = src.daily_seconds(user: @user, from: Date.new(2026, 11, 10), to: Date.new(2026, 11, 10))
    assert_equal [ 2 ], days.map(&:seconds)
  end

  test "bad rows are skipped and counted" do
    src = source(<<~CSV)
      slack_id,date,seconds,project
      U01ABCDEF,2026-11-10,600,ok
      ,2026-11-10,600,
      U01ABCDEF,not-a-date,600,
      U01ABCDEF,2026-02-30,600,
      U01ABCDEF,2026-11-10,-5,
      U01ABCDEF,2026-11-10,abc,
      U01ABCDEF,2026-11-10,86401,
      U01ABCDEF,2026-11-10,12.5,
      bad id!,2026-11-10,600,
      U01ABCDEF,2026-11-10,600,#{'p' * 121}
    CSV

    assert_equal 9, src.invalid_row_count
    assert_equal 10, src.row_count
    assert_equal [ 600 ], src.daily_seconds(user: @user, from: nil, to: nil).map(&:seconds)
  end

  test "a repeated date and project keeps the last row" do
    src = source("slack_id,date,seconds,project\nU01ABCDEF,2026-11-10,100,p\nU01ABCDEF,2026-11-10,200,p\n")
    assert_equal [ 200 ], src.daily_seconds(user: @user, from: nil, to: nil).map(&:seconds)
  end

  test "counts unknown slack ids without exposing them" do
    src = source("slack_id,date,seconds\nU01ABCDEF,2026-11-10,1\nU0NOBODY1,2026-11-10,1\nU0NOBODY1,2026-11-11,1\nU0NOBODY2,2026-11-11,1\n")
    assert_equal 2, src.unknown_slack_id_count
    assert_equal [ @user.id ], src.users.pluck(:id)
  end

  test "a user without a slack id, or not in the file, gets nothing" do
    src = source("slack_id,date,seconds\nU01ABCDEF,2026-11-10,1\n")
    assert_equal [], src.daily_seconds(user: users(:new_user), from: nil, to: nil)
  end

  test "handles a byte order mark and spaces around headers" do
    src = source("﻿slack_id, date ,seconds\nU01ABCDEF,2026-11-10,60\n")
    assert_equal [ 60 ], src.daily_seconds(user: @user, from: nil, to: nil).map(&:seconds)
  end

  test "refuses a missing file, missing columns and a malformed file" do
    assert_raises(ArgumentError) { Hackatime::CsvSource.new("/nonexistent/hours.csv") }
    assert_raises(ArgumentError) { Hackatime::CsvSource.new(nil) }
    assert_raises(ArgumentError) { source("slack_id,date\nU01ABCDEF,2026-11-10\n") }
    assert_raises(ArgumentError) { source(%(slack_id,date,seconds\nU01ABCDEF,"2026-11-10,5\n)) }
  end

  test "never logs anything" do
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    src = source("slack_id,date,seconds\nU01ABCDEF,2026-11-10,60\nbad id,x,y\n")
    src.daily_seconds(user: @user, from: nil, to: nil)
    src.unknown_slack_id_count
    assert_not_includes io.string, "U01ABCDEF"
  ensure
    Rails.logger = original
  end
end
