require "test_helper"

# config/game.yml: live Hackatime hours are the production default, and nothing else changes. Development and test keep
# the null source so no test or local run ever calls Hackatime; HOURS_SOURCE still overrides everywhere.
module Hackatime
  class HoursSourceConfigTest < ActiveSupport::TestCase
    def hours_source(env) = Rails.application.config_for(:game, env: env).dig(:hours, :hours_source)

    def with_hours_source(value)
      original = ENV["HOURS_SOURCE"]
      value.nil? ? ENV.delete("HOURS_SOURCE") : ENV["HOURS_SOURCE"] = value
      yield
    ensure
      original.nil? ? ENV.delete("HOURS_SOURCE") : ENV["HOURS_SOURCE"] = original
    end

    def as_env(name)
      original = Rails.env
      Rails.env = name
      yield
    ensure
      Rails.env = original
    end

    test "the production config resolves to http, development and test to null" do
      assert_equal "http", hours_source("production")
      assert_nil hours_source("development")
      assert_nil hours_source("test")
    end

    test "only hours_source differs between production and the shared tunables" do
      production = Rails.application.config_for(:game, env: "production").to_h.deep_dup
      development = Rails.application.config_for(:game, env: "development").to_h.deep_dup
      production[:hours] = production[:hours].except(:hours_source)
      development[:hours] = development[:hours].except(:hours_source)
      assert_equal development, production # the deep merge kept every other tunable
    end

    test "Hackatime.source follows the environment's default and HOURS_SOURCE overrides it" do
      with_hours_source(nil) do
        assert_equal "null", Hackatime.source_name # the test environment
        as_env("production") do
          assert_equal "http", Hackatime.source_name
          assert_instance_of HttpSource, Hackatime.source
        end
      end
      as_env("production") do
        with_hours_source("null") { assert_equal "null", Hackatime.source_name }
        with_hours_source("http") { assert_equal "http", Hackatime.source_name }
      end
      with_hours_source("http") { assert_equal "http", Hackatime.source_name } # and in test
    end
  end
end
