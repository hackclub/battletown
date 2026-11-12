require "test_helper"

# require_feature! and feature? in a controller. RoutingError is what the app renders as the plain 404 an unknown
# path gets (the same mechanism as a non-admin on /admin).
class FeatureFlagsControllerTest < ActionController::TestCase
  class ProbeController < ApplicationController
    before_action { require_feature!(:team) }

    def show = render(plain: "team page #{feature?(:team)}")
  end

  tests ProbeController

  def probe
    with_routing do |set|
      set.draw { get "probe", to: "feature_flags_controller_test/probe#show" }
      yield
    end
  end

  test "the action is a 404 while the flag is off" do
    probe do
      error = assert_raises(ActionController::RoutingError) { get :show }
      assert_equal "Not Found", error.message
    end
  end

  test "the action works once the flag is on, and off again after" do
    probe do
      with_feature(:team) do
        get :show
        assert_response :success
        assert_equal "team page true", response.body
      end
      assert_raises(ActionController::RoutingError) { get :show }
    end
  end

  test "a misspelled flag raises instead of staying quietly off" do
    controller = ProbeController.new
    assert_raises(ArgumentError) { controller.send(:require_feature!, :tem) }
    assert_raises(ArgumentError) { controller.send(:feature?, :tem) }
  end
end
