# Test-only stand-in for Hack Club Auth's whoami endpoint (the route exists only in the test environment).
# /test_support/whoami/:mode answers like the real one would: signed_in (with a name and an email), signed_out, error, slow.
class WhoamiStubController < ActionController::Base
  def show
    case params[:mode]
    when "signed_in" then render json: { signed_in: true, first_name: "Ada", email: "ada@example.com" }
    when "signed_in_long" then render json: { signed_in: true, first_name: "A" * 200 }
    when "signed_out" then render json: { signed_in: false }
    when "slow" then sleep 2.4 and render json: { signed_in: true, first_name: "Ada" }
    else head :internal_server_error
    end
  end
end
