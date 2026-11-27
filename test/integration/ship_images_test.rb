require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/ship_images_helper"

# Ship screenshots (flag `ship_screenshots`): the form, the serving route, staff review and what the flag-off state looks like.
class ShipImagesTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport
  include ShipImagesHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @project = make_project(@user)
    (7..9).each { |day| code(@user, Date.new(2026, 11, day), HOUR) }
    @other = users(:new_user)
    @other.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def sign_out = delete(logout_path)

  def pic(position, bytes = png_bytes(20 + position, 10), alt: nil)
    { file: upload_file(bytes), alt: alt }.compact.then { |slot| { position.to_s => slot } }
  end

  def ship_form(action: "draft", **images)
    { ship: ship_attrs, ship_action: action, images: images.values.reduce({}, :merge) }
  end

  def create_with(*slots, action: "draft")
    post project_ships_path(@project), params: { ship: ship_attrs, ship_action: action, images: slots.reduce({}, :merge) }
    Ship.order(:id).last
  end

  def stored(ship) = ShipImage.where(ship_id: ship.id).order(:position).to_a

  # A ship with one stored picture, without going through the form.
  def ship_with_image(status: "submitted", user: @user, project: @project)
    ship = submit_ship(project, submit: status != "draft")
    processed = ShipImages::Processor.call(upload_file(png_bytes(30, 20)))
    ShipImage.create!(ship: ship, user: user, position: 1, content: processed.content, width: processed.width, height: processed.height,
                      byte_size: processed.byte_size, sha256: processed.sha256, alt: "Cows")
    ship
  end

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = user.hca_uid

  # --- the flag is off (the default): ships work exactly as before ---

  test "flag off: the form has no upload control and no mention of screenshots" do
    sign_in_as @user
    get new_project_ship_path(@project)
    assert_response :success
    assert_select "input[type=file]", 0
    assert_select "form[enctype='multipart/form-data']", 0
    assert_no_match(/screenshot/i, response.body)
  end

  test "flag off: a ship is created without images even if the request carries some" do
    sign_in_as @user
    assert_difference("Ship.count", 1) { create_with(pic(1)) }
    assert_equal 0, ShipImage.count
  end

  test "flag off: the image route, the staff removal route and the page section do not exist" do
    ship = ship_with_image
    sign_in_as @user
    get ship_image_path(ship, 1)
    assert_response :not_found
    get ship_path(ship)
    assert_response :success
    assert_select "img[src*=images]", 0
    assert_no_match(/Screenshots/, response.body)

    make_admin(@user)
    get admin_ship_path(ship)
    assert_select ".ship-shots", 0
    delete admin_ship_image_path(ship_id: ship.id, position: 1)
    assert_response :not_found
    assert_equal 1, ShipImage.count
  end

  test "flag off: the prune task does nothing" do
    ship = ship_with_image
    assert Ships::Withdraw.call(ship: ship)
    Ship.where(id: ship.id).update_all(updated_at: 90.days.ago)
    assert_predicate ShipImages::Prune.call, :skipped
    assert_equal 1, ShipImage.count
  end

  # --- the flag is on: the form ---

  test "flag on: the form shows three upload slots with an accept hint, and the copy for teens" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      get new_project_ship_path(@project)
      assert_select "form[enctype='multipart/form-data']"
      assert_select "input[type=file][accept='image/png,image/jpeg,image/webp,image/gif']", 3
      assert_select "input[type=file][name='images[2][file]']"
      assert_select "input[name='images[1][alt]'][maxlength='140']"
      assert_match(/Add up to 3 screenshots so reviewers can see what you made \(optional\)/, response.body)
      assert_match(/leave out your face, address, passwords and anyone else's personal info/, response.body)
      assert_match(/Only you and the Battletown review team can see these/, response.body)
    end
  end

  test "flag on: a ship still submits without any image" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      ship = create_with(action: "submit")
      assert_redirected_to ship_path(ship)
      assert_equal "submitted", ship.status
      assert_equal 0, ShipImage.count
    end
  end

  test "flag on: uploaded pictures are stored as WebP at their positions and the ship page shows them to the owner" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      ship = create_with(pic(1, jpeg_with_gps_exif(60, 40), alt: "The cows"), pic(3), action: "submit")
      assert_redirected_to ship_path(ship)
      images = stored(ship)
      assert_equal [ 1, 3 ], images.map(&:position)
      assert(images.all? { |image| image.content.byteslice(8, 4) == "WEBP" && image.user_id == @user.id })
      assert_not_includes images.first.content, "GPS"

      get ship_path(ship)
      assert_select ".ship-shots img", 2
      assert_select ".ship-shots img[src='#{ship_image_path(ship, 1)}'][alt='The cows']"
      assert_select ".ship-shots img[src='#{ship_image_path(ship, 3)}'][alt='Screenshot 3']"
      assert_select "form[action*=images]", 0
    end
  end

  test "flag on: a rejected file shows a friendly message, saves nothing and keeps the other fields" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      assert_no_difference([ "Ship.count", "ShipImage.count" ]) do
        post project_ships_path(@project), params: { ship: ship_attrs(description: "Kept words"), ship_action: "submit",
                                                    images: pic(1).merge("2" => { file: upload_file("<svg/>", name: "logo.png", type: "image/png") }) }
      end
      assert_response :unprocessable_content
      assert_select ".alert--danger li", text: /Screenshot 2: That doesn't look like a PNG, JPEG, WebP or GIF/
      assert_select "textarea", text: /Kept words/
    end
  end

  test "flag on: an oversized-dimension picture and a fourth slot are refused with their own messages" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      post project_ships_path(@project), params: { ship: ship_attrs, ship_action: "draft",
                                                  images: pic(1, png_bytes(6000, 6000)).merge("4" => { file: upload_file(png_bytes) }) }
      assert_response :unprocessable_content
      assert_select ".alert--danger li", text: /Screenshot 1: That picture is too large/
      assert_select ".alert--danger li", text: /You can add up to 3 screenshots/
      assert_equal 0, Ship.count
    end
  end

  test "flag on: a draft's pictures can be replaced and removed, and the edit form shows them" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      ship = create_with(pic(1), pic(2))
      get edit_ship_path(ship)
      assert_select ".ship-images__thumb", 2
      assert_select "input[type=checkbox][name='images[1][remove]']"

      before = stored(ship).map(&:sha256)
      patch ship_path(ship), params: { ship: ship_attrs, ship_action: "draft", images: pic(1, png_bytes(77, 33)).merge("2" => { remove: "1" }) }
      assert_redirected_to ship_path(ship)
      images = stored(ship)
      assert_equal [ 1 ], images.map(&:position)
      assert_equal 77, images.first.width
      assert_not_equal before.first, images.first.sha256
    end
  end

  test "flag on: a draft can be submitted with its pictures kept" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      ship = create_with(pic(1))
      patch ship_path(ship), params: { ship: ship_attrs, ship_action: "submit" }
      assert_equal "submitted", ship.reload.status
      assert_equal 1, stored(ship).size
    end
  end

  test "flag on: pictures are read-only once the ship is submitted" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      ship = create_with(pic(1), action: "submit")
      patch ship_path(ship), params: { ship: ship_attrs, images: { "1" => { remove: "1" }, "2" => { file: upload_file(png_bytes(9, 9)) } } }
      assert_redirected_to ship_path(ship)
      assert_equal [ 1 ], stored(ship).map(&:position)
      get edit_ship_path(ship)
      assert_redirected_to ship_path(ship)
      assert_select "input[type=file]", 0
    end
  end

  test "flag on: fix and ship again offers the rejected ship's pictures and keeps them" do
    with_feature(:ship_screenshots) do
      rejected = ship_with_image
      rejected.update_columns(status: "rejected", rejection_reason: "More please", reviewed_at: Time.current)
      sign_in_as @user
      get new_project_ship_path(@project, from: rejected.id)
      assert_select "input[type=hidden][name=from][value='#{rejected.id}']"
      assert_select ".ship-images__thumb[src='#{ship_image_path(rejected, 1)}']"

      post project_ships_path(@project), params: { ship: ship_attrs, ship_action: "draft", from: rejected.id }
      fresh = Ship.order(:id).last
      assert_not_equal rejected.id, fresh.id
      assert_equal [ 1 ], stored(fresh).map(&:position)
      assert_equal 1, stored(rejected).size
    end
  end

  test "flag on: someone else's rejected ship is never carried over" do
    with_feature(:ship_screenshots) do
      theirs_project = make_project(@other, name: "Theirs", hackatime: "theirs")
      (7..9).each { |day| code(@other, Date.new(2026, 11, day), HOUR, hackatime: "theirs") }
      theirs = ship_with_image(user: @other, project: theirs_project)
      theirs.update_columns(status: "rejected", rejection_reason: "No", reviewed_at: Time.current)
      sign_in_as @user
      post project_ships_path(@project), params: { ship: ship_attrs, ship_action: "draft", from: theirs.id }
      assert_equal 0, stored(Ship.order(:id).last).size
    end
  end

  # --- serving ---

  test "flag on: the owner gets the WebP with every protective header" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image
      sign_in_as @user
      get ship_image_path(ship, 1)
      assert_response :success
      assert_equal "image/webp", response.media_type
      assert_equal "WEBP", response.body.byteslice(8, 4)
      assert_equal ShipImage.find_by!(ship_id: ship.id).content, response.body.b
      assert_equal "inline", response.headers["Content-Disposition"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_equal "sandbox", response.headers["Content-Security-Policy"]
      assert_no_match(/filename/, response.headers["Content-Disposition"])
    end
  end

  test "flag on: signed-out visitors, other users and a missing picture all get the same 404" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image
      missing = (get("/ships/#{ship.id}/images/1/nope") && response.body)

      get ship_image_path(ship, 1)
      assert_response :not_found
      assert_equal missing, response.body

      sign_in_as @other
      get ship_image_path(ship, 1)
      assert_response :not_found
      assert_equal missing, response.body

      sign_out
      sign_in_as @user
      get ship_image_path(ship, 2)
      assert_response :not_found
      get "/ships/#{ship.id}/images/4"
      assert_response :not_found
      get "/ships/#{ship.id}/images/abc"
      assert_response :not_found
      get ship_image_path(ship.id + 1000, 1)
      assert_response :not_found
    end
  end

  test "flag on: an admin can see a submitted ship's pictures but not a draft's" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image
      make_admin(@other)
      sign_in_as @other
      get ship_image_path(ship, 1)
      assert_response :success
      assert_equal "image/webp", response.media_type

      ship.update_columns(status: "draft", submitted_at: nil)
      get ship_image_path(ship, 1)
      assert_response :not_found
    end
  end

  test "flag on: a pictures route answers 404 again the moment the flag goes off" do
    ship = ship_with_image
    sign_in_as @user
    with_feature(:ship_screenshots) do
      get ship_image_path(ship, 1)
      assert_response :success
    end
    get ship_image_path(ship, 1)
    assert_response :not_found
  end

  # --- staff review ---

  test "flag on: the admin review page shows the pictures in the admin style and can remove one" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image
      make_admin(@other)
      sign_in_as @other
      get admin_ship_path(ship)
      assert_response :success
      assert_select ".admin-only .ship-shots img[src='#{ship_image_path(ship, 1)}']"
      assert_select "form[action='#{admin_ship_image_path(ship_id: ship.id, position: 1)}'] button", text: /Remove screenshot 1/

      delete admin_ship_image_path(ship_id: ship.id, position: 1)
      assert_redirected_to admin_ship_path(ship)
      assert_equal 0, ShipImage.count
      assert_equal "submitted", ship.reload.status
    end
  end

  test "flag on: non-admins and signed-out visitors cannot remove a picture and get a 404" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image
      delete admin_ship_image_path(ship_id: ship.id, position: 1)
      assert_response :not_found
      sign_in_as @user
      delete admin_ship_image_path(ship_id: ship.id, position: 1)
      assert_response :not_found
      get admin_ship_path(ship)
      assert_response :not_found
      assert_equal 1, ShipImage.count
    end
  end

  test "flag on: staff cannot remove a picture from a draft" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image(status: "draft")
      make_admin(@other)
      sign_in_as @other
      delete admin_ship_image_path(ship_id: ship.id, position: 1)
      assert_response :not_found
      assert_equal 1, ShipImage.count
    end
  end

  # --- nothing else embeds a screenshot ---

  test "flag on: the dashboard, the ships list and the projects list never embed a screenshot" do
    with_feature(:ship_screenshots) do
      ship_with_image
      sign_in_as @user
      [ dashboard_path, ships_path, projects_path ].each do |path|
        get path
        assert_response :success
        assert_no_match(%r{/ships/\d+/images/}, response.body, path)
      end
    end
  end

  # --- privacy ---

  test "uploaded files and descriptions are filtered from the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("images" => { "1" => { "file" => "Jane-Doe-passport.png", "alt" => "my house" } })
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered["images"]
  end

  test "the original file name is never stored" do
    with_feature(:ship_screenshots) do
      sign_in_as @user
      post project_ships_path(@project), params: { ship: ship_attrs, ship_action: "draft",
                                                  images: { "1" => { file: upload_file(png_bytes, name: "Jane-Doe-passport.png") } } }
      row = ActiveRecord::Base.connection.select_one("SELECT * FROM ship_images LIMIT 1")
      assert_not_includes row.values.map(&:to_s).join, "Jane-Doe"
      assert_not_includes ShipImage.column_names.join(","), "filename"
    end
  end

  # --- cascades through the real deletion paths ---

  test "withdrawing a ship keeps its pictures for the retention period, and the prune task then removes them" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image(status: "submitted")
      assert Ships::Withdraw.call(ship: ship)

      result = ShipImages::Prune.call
      assert_equal 0, result.withdrawn
      assert_equal 1, ShipImage.count

      travel_to(31.days.from_now) { result = ShipImages::Prune.call }
      assert_equal 1, result.withdrawn
      assert_equal 0, ShipImage.count
    end
  end
end
