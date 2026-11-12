require "test_helper"

# Helpers for the coin ledger, settlement and approval tests.
module CoinsHelper
  # Any object answering seconds_by_date(user, range) works as the daily seconds source; this one serves a fixed hash
  # { Date => seconds } and records the ranges it was asked for.
  class StubHoursSource
    attr_reader :requests
    attr_accessor :seconds

    def initialize(seconds = {})
      @seconds = seconds
      @requests = []
    end

    def seconds_by_date(_user, range)
      @requests << range
      seconds.select { |date, _| range.cover?(date) }
    end
  end

  # time_zone is written past the validation (which only knows Rails zone names) so tests can use any IANA id.
  def build_user(time_zone: "UTC", created_on: Date.new(2026, 11, 1))
    user = User.create!(hca_uid: "ident!coins-#{SecureRandom.hex(6)}", created_at: Time.utc(created_on.year, created_on.month, created_on.day, 12))
    user.update_columns(time_zone: time_zone)
    user
  end

  # One quick-qualifying day (15 minutes) per date.
  def quick_days(range, seconds: 900) = range.to_h { |date| [ date, seconds ] }
end
