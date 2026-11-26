require "test_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ship_images_helper"

class AdminBossesTest < ActionDispatch::IntegrationTest
  include BossesHelper
  include ShipImagesHelper

  # "Today" for the create tests: the latest boss (Boss 2) ends Thursday 26 Nov, so the next free Friday is 27 Nov.
  TODAY = Time.utc(2026, 11, 24, 12)
  NEXT_FRIDAY = Date.new(2026, 11, 27)

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @boss = make_boss(starts_on: Date.new(2026, 11, 20), name: "Boss 2", hp_seconds: 500 * HOUR)
    @past = make_boss(starts_on: Date.new(2026, 11, 6), name: "Boss 0")
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = user.hca_uid

  def update_params(**boss) = { boss: boss }

  test "signed-out visitors get a 404 on every bosses route" do
    get "/admin/bosses"
    assert_response :not_found
    get "/admin/bosses/#{@boss.id}/edit"
    assert_response :not_found
    patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Hacked")
    assert_response :not_found
    assert_equal "Boss 2", @boss.reload.name
  end

  test "non-admins get the same 404 and cannot change a boss" do
    sign_in_as users(:onboarded)
    missing = (get("/definitely-not-a-page") && response.body)

    get "/admin/bosses"
    assert_response :not_found
    assert_equal missing, response.body
    get "/admin/bosses/#{@boss.id}/edit"
    assert_response :not_found
    patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Hacked", hp_hours: 1)
    assert_response :not_found
    @boss.reload
    assert_equal "Boss 2", @boss.name
    assert_equal 500 * HOUR, @boss.hp_seconds
  end

  test "an admin sees the list: aggregate numbers, no names, no-store" do
    users(:new_user).update!(display_name: "Secret Person")
    ship_damage(users(:new_user), 2 * HOUR, on: Date.new(2026, 11, 20))
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 21, 12) do
      get "/admin/bosses"
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "title", text: "Admin bosses - BattleTown"
    assert_select ".admin-only table.admin-table tbody tr", 2
    assert_select "tbody tr:first-child th", "Boss 0"
    damage = ActiveSupport::NumberHelper.number_to_rounded(Bosses::Damage.for(@boss) / 3600.0, precision: 1) # however damage is derived, the list shows the same number
    assert_select "tbody tr", text: /Boss 2.*500.*#{Regexp.escape(damage)}.*In progress/m
    assert_select "a[href=?]", "/admin/bosses/#{@boss.id}/edit", 1
    assert_not_includes response.body, "Secret Person"
    assert_not_includes response.body, users(:new_user).email
  end

  test "the admin dashboard links to the bosses" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin"
    assert_select ".admin-only a[href='/admin/bosses']", "Weekly bosses"
  end

  test "an admin edits name, art and health before the boss starts" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 12, 12) do
      get "/admin/bosses/#{@boss.id}/edit"
      assert_response :success
      assert_select "form input[name='boss[hp_hours]']:not([disabled])", 1
      assert_select "form input[name='boss[starts_on]']", 0
      assert_select "form input[name='boss[ends_on]']", 0

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "The Linter", art_key: "placeholder", hp_hours: "120")
      assert_redirected_to "/admin/bosses"
    end

    @boss.reload
    assert_equal "The Linter", @boss.name
    assert_equal 120 * HOUR, @boss.hp_seconds
  end

  test "health is locked once the boss has started, but the name can still change" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)

    travel_to Time.utc(2026, 11, 21, 12) do
      get "/admin/bosses/#{@boss.id}/edit"
      assert_select "input[name='boss[hp_hours]'][disabled]", 1
      assert_select "form", text: /Locked/

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Renamed", hp_hours: "1")
      assert_response :unprocessable_content
      assert_select ".admin-form__errors", text: /can't change once the boss has started/
      assert_equal 500 * HOUR, @boss.reload.hp_seconds
      assert_equal "Boss 2", @boss.name, "nothing is saved when any field is refused"

      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "Renamed")
      assert_redirected_to "/admin/bosses"
    end
    assert_equal "Renamed", @boss.reload.name
    assert_equal 500 * HOUR, @boss.hp_seconds
  end

  test "dates and defeat cannot be changed through the form" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    travel_to Time.utc(2026, 11, 12, 12) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Same", starts_on: "2026-12-01", ends_on: "2026-12-07", defeated_at: Time.current.iso8601, id: 999 } }
    end
    @boss.reload
    assert_equal Date.new(2026, 11, 20), @boss.starts_on
    assert_equal Date.new(2026, 11, 26), @boss.ends_on
    assert_nil @boss.defeated_at
  end

  test "invalid input is refused with a message" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    travel_to Time.utc(2026, 11, 12, 12) do
      patch "/admin/bosses/#{@boss.id}", params: update_params(name: "", hp_hours: "0")
      assert_response :unprocessable_content
      assert_select ".admin-form__errors li", minimum: 2

      patch "/admin/bosses/#{@boss.id}", params: update_params(hp_hours: "lots")
      assert_response :unprocessable_content
    end
    assert_equal 500 * HOUR, @boss.reload.hp_seconds
  end

  test "an unknown boss id is a 404" do
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
    get "/admin/bosses/0/edit"
    assert_response :not_found
  end

  # --- adding a boss and managing its picture ---

  # A PNG whose right half is fully transparent (a boss is a cut-out).
  def cutout_png(width = 40, height = 20)
    colour = solid(width, height, [ 200, 40, 40 ])
    opaque_left = Vips::Image.black(width / 2, height).new_from_image([ 255 ]).embed(0, 0, width, height, extend: :black)
    colour.bandjoin(opaque_left.cast(:uchar)).pngsave_buffer
  end

  def png_upload(bytes = cutout_png, name: "boss.png") = upload_file(bytes, name: name, type: "image/png")

  def new_boss_params(**boss) = { boss: { name: "The Linter", hp_hours: "120", starts_on: NEXT_FRIDAY.iso8601 }.merge(boss) }

  def admin!
    make_admin(users(:onboarded))
    sign_in_as users(:onboarded)
  end

  def create_boss(**boss)
    travel_to(TODAY) { post "/admin/bosses", params: new_boss_params(**boss) }
  end

  def give_art(boss, alt: "A tall red boss")
    boss.attach_art(ShipImages::Processor.call(png_upload, config: Bosses::ArtConfig.current))
    boss.update!(art_alt: alt)
    boss
  end

  def audit_rows(action) = AdminAuditEvent.where(action: action).order(:id).to_a

  test "signed-out visitors and non-admins get a 404 on the new form and on create, and nothing is saved" do
    get "/admin/bosses/new"
    assert_response :not_found
    assert_no_difference "Boss.count" do
      post "/admin/bosses", params: new_boss_params
      assert_response :not_found
    end

    sign_in_as users(:onboarded)
    missing = (get("/definitely-not-a-page") && response.body)
    get "/admin/bosses/new"
    assert_response :not_found
    assert_equal missing, response.body
    assert_no_difference "Boss.count" do
      post "/admin/bosses", params: new_boss_params(art_upload: png_upload)
      assert_response :not_found
    end
    assert_empty audit_rows("boss_created")
  end

  test "the new form offers the next ten free Fridays, defaults to the one after the latest boss and describes each field" do
    admin!
    travel_to(TODAY) { get "/admin/bosses/new" }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "form[action='/admin/bosses'][method=post][enctype='multipart/form-data']"
    assert_select "select[name='boss[starts_on]'] option", 10
    assert_select "select[name='boss[starts_on]'] option[selected][value='2026-11-27']", 1
    assert_select "select[name='boss[starts_on]'] option[value='2026-11-13']", 0, "a week in the past is not offered"
    assert_select "select[name='boss[starts_on]'] option[value='2026-11-20']", 0, "a week that already has a boss is not offered"
    assert_select "label[for=boss_name]"
    assert_select "label[for=boss_hp_hours]"
    assert_select "label[for=boss_starts_on]"
    assert_select "label[for=boss_art_upload]"
    assert_select "input[type=file][name='boss[art_upload]'][aria-describedby=boss-art-hint]"
    assert_select "#boss-art-hint", text: /PNG, JPEG, WebP or GIF.*5 MB.*transparen.*1600 pixels on its longest side/m
    assert_select "label[for=boss_art_alt]"
    assert_select "input[name='boss[art_alt]'][maxlength='200'][aria-describedby=boss-alt-hint]"
    assert_select "input[name='boss[lock_version]']", 0
    assert_select "input[name='boss[ends_on]']", 0
    assert_select "input[name='boss[use_previous_art]']", 0, "nothing to copy while the latest boss has no picture"
  end

  test "the form offers last week's picture, ticked, when the latest boss has one" do
    give_art(@boss)
    admin!
    travel_to(TODAY) { get "/admin/bosses/new" }
    assert_select "input[type=checkbox][name='boss[use_previous_art]'][checked]", 1
    assert_select "label.option", text: /Use last week's picture/
  end

  test "an admin adds a boss without a picture: the week is Friday to Thursday, the built-in picture is used, one audit row with ids only" do
    admin!
    assert_difference "Boss.count", 1 do
      create_boss(name: "Secret Boss Name")
    end
    assert_redirected_to "/admin/bosses"
    assert_equal "Added Secret Boss Name.", flash[:notice]

    boss = Boss.find_by!(name: "Secret Boss Name")
    assert_equal NEXT_FRIDAY, boss.starts_on
    assert_equal Date.new(2026, 12, 3), boss.ends_on
    assert_equal 120 * HOUR, boss.hp_seconds
    assert_not boss.art?
    assert_equal "placeholder", boss.art_key
    assert_equal "bosses/placeholder.webp", boss.art_path

    event = audit_rows("boss_created").sole
    assert_equal users(:onboarded).id, event.actor_id
    assert_equal [ "Boss", boss.id ], [ event.subject_type, event.subject_id ]
    assert_equal({ "boss_id" => boss.id, "hp_seconds" => 120 * HOUR, "picture" => false }, event.metadata)
    assert_empty AdminAudit::Metadata.problems(event.metadata)
    assert_not_includes event.metadata.to_json, "Secret Boss Name"
  end

  test "an admin adds a boss with a picture: re-encoded to a WebP that keeps its transparency, alt text saved, served at its public path" do
    admin!
    create_boss(art_upload: png_upload, art_alt: "A red boss, cut out")
    assert_redirected_to "/admin/bosses"

    boss = Boss.find_by!(name: "The Linter")
    assert_predicate boss, :art?
    assert_equal "A red boss, cut out", boss.art_alt
    assert_equal [ 40, 20 ], [ boss.art_width, boss.art_height ]
    content = Boss.art_content_for(boss.id)
    assert_equal "RIFF", content.byteslice(0, 4)
    assert_equal "WEBP", content.byteslice(8, 4)
    assert_equal content.bytesize, boss.art_byte_size
    assert_equal Digest::SHA256.hexdigest(content), boss.art_sha256
    decoded = Vips::Image.webpload_buffer(content)
    assert_equal 4, decoded.bands, "the alpha channel survives"
    assert_equal 0, decoded.extract_band(3).getpoint(35, 10).first, "the transparent half is still transparent"
    assert_equal 255, decoded.extract_band(3).getpoint(5, 10).first

    assert_equal true, audit_rows("boss_created").sole.metadata["picture"]
    assert_not_includes audit_rows("boss_created").sole.metadata.to_json, "red boss"

    get boss.art_path
    assert_response :success
    assert_equal content, response.body.b
  end

  test "ticking use last week's picture copies the picture and alt text of the latest boss; a typed alt text replaces the copied one" do
    give_art(@boss, alt: "Last week's boss")
    admin!
    create_boss(name: "Copy A", use_previous_art: "1")
    copy = Boss.find_by!(name: "Copy A")
    assert_equal @boss.art_sha256, copy.art_sha256
    assert_equal "Last week's boss", copy.art_alt
    assert_equal Boss.art_content_for(@boss.id), Boss.art_content_for(copy.id)
    assert_equal true, audit_rows("boss_created").last.metadata["picture"]

    create_boss(name: "Copy B", use_previous_art: "1", starts_on: "2026-12-11", art_alt: "My own words")
    assert_equal "My own words", Boss.find_by!(name: "Copy B").art_alt
    assert_equal @boss.art_sha256, Boss.find_by!(name: "Copy B").art_sha256
  end

  test "leaving the box unticked keeps the built-in picture, and an uploaded picture wins over the copy" do
    give_art(@boss)
    admin!
    create_boss(name: "Plain")
    assert_not Boss.find_by!(name: "Plain").art?

    create_boss(name: "Mine", starts_on: "2026-12-04", use_previous_art: "1", art_upload: png_upload(solid(30, 30).pngsave_buffer, name: "other.png"), art_alt: "Another boss")
    mine = Boss.find_by!(name: "Mine")
    assert_not_equal @boss.art_sha256, mine.art_sha256
    assert_equal [ 30, 30 ], [ mine.art_width, mine.art_height ]
    assert_equal "Another boss", mine.art_alt
  end

  test "a week that is not a Friday is refused with a 422, the form is shown again and nothing is saved" do
    admin!
    assert_no_difference [ "Boss.count", "AdminAuditEvent.count" ] do
      create_boss(starts_on: "2026-11-28", name: "Saturday boss")
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li a[href='#boss_starts_on']", text: /must be a Friday/
    assert_select "input[name='boss[name]'][value='Saturday boss']", 1, "what was typed stays in the form"
    assert_select "select#boss_starts_on[aria-invalid=true]"
  end

  test "a Friday that is not on offer (long past, years away, or already past since the form was opened) is refused" do
    admin!
    assert_no_difference [ "Boss.count", "AdminAuditEvent.count" ] do
      [ "1999-01-01", "9999-12-31", "2026-11-13", "2026-11-20" ].each do |friday|
        create_boss(starts_on: friday)
        assert_response :unprocessable_content, friday
        assert_select ".admin-form__errors li a[href='#boss_starts_on']", text: /isn't one of the weeks on offer/
      end
    end
    create_boss(starts_on: "2026-11-27")
    assert_redirected_to "/admin/bosses"
  end

  test "a week that overlaps another boss is refused with a 422 and nothing is saved" do
    admin!
    assert_no_difference [ "Boss.count", "AdminAuditEvent.count" ] do
      create_boss(starts_on: "2026-11-20")
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", text: /already been taken|overlap/

    assert_no_difference "Boss.count" do
      create_boss(starts_on: "")
      assert_response :unprocessable_content
      create_boss(starts_on: "not a date")
      assert_response :unprocessable_content
    end
  end

  test "a file that is not a picture is refused with a plain message and nothing is saved" do
    admin!
    bad = upload_file("<?php echo 1;", name: "boss.png", type: "image/png")
    assert_no_difference [ "Boss.count", "AdminAuditEvent.count" ] do
      create_boss(art_upload: bad, art_alt: "Anything")
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li a[href='#boss_art_upload']", text: /The picture: /
    assert_select "input[name='boss[name]'][value='The Linter']", 1
  end

  test "a picture over the size limit, or with too many pixels, is refused and nothing is saved" do
    admin!
    huge = upload_file(png_bytes(40, 40), name: "huge.png")
    config = Bosses::ArtConfig.from_hash(max_upload_bytes: 100, max_megapixels: 16, max_edge_px: 1600, webp_quality: 85)
    stub_method(Bosses::ArtConfig, :current, -> { config }) do
      assert_no_difference "Boss.count" do
        create_boss(art_upload: huge, art_alt: "Too big")
      end
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", text: /The picture: That file is .*the limit is/
  end

  test "alt text is needed with a picture and cannot be longer than 200 characters" do
    admin!
    assert_no_difference "Boss.count" do
      create_boss(art_upload: png_upload)
      assert_response :unprocessable_content
      assert_select ".admin-form__errors li a[href='#boss_art_alt']", text: /Alt text is needed to describe the picture/

      create_boss(art_upload: png_upload, art_alt: "a" * 201)
      assert_response :unprocessable_content
      assert_select ".admin-form__errors li", text: /Alt text is too long/
      assert_select "input#boss_art_alt[aria-invalid=true]"
    end

    create_boss(art_upload: png_upload, art_alt: "a" * 200)
    assert_redirected_to "/admin/bosses"
  end

  test "alt text typed without any picture is not kept" do
    admin!
    create_boss(art_alt: "Describes nothing")
    assert_nil Boss.find_by!(name: "The Linter").art_alt
  end

  test "health is checked when adding a boss" do
    admin!
    assert_no_difference "Boss.count" do
      create_boss(hp_hours: "0")
      assert_response :unprocessable_content
      create_boss(hp_hours: "lots")
      assert_response :unprocessable_content
      create_boss(name: "")
      assert_response :unprocessable_content
      create_boss(name: "n" * 61)
      assert_response :unprocessable_content
    end
    assert_select ".admin-form__errors li a[href='#boss_name']"
  end

  test "dates and the art key cannot be forced through the create form" do
    admin!
    create_boss(ends_on: "2027-03-01", art_key: "../etc/passwd", defeated_at: Time.current.iso8601, id: "999")
    boss = Boss.find_by!(name: "The Linter")
    assert_equal Date.new(2026, 12, 3), boss.ends_on
    assert_equal "placeholder", boss.art_key
    assert_nil boss.defeated_at
  end

  test "two admins adding the same week at once: the database refuses the second and the form says so" do
    admin!
    travel_to(TODAY) do
      get "/admin/bosses/new"
      Boss.create!(name: "Faster admin", art_key: "placeholder", starts_on: NEXT_FRIDAY, hp_seconds: HOUR)
      # The form was drawn before the other boss was saved; the model's own check and the database's both refuse the overlap.
      post "/admin/bosses", params: new_boss_params(name: "Raced")
    end
    assert_response :unprocessable_content
    assert_equal 0, Boss.where(name: "Raced").count
    assert_empty audit_rows("boss_created")
  end

  test "the list shows a thumbnail with its alt text and loads no picture bytes" do
    give_art(@boss, alt: "A tall red boss")
    admin!
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) }
    travel_to(TODAY) do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/admin/bosses" }
    end

    assert_response :success
    assert_select "img.admin-boss-thumb[src=?][alt=?]", "/bosses/#{@boss.id}/art?v=#{@boss.art_sha256.first(12)}", "A tall red boss"
    assert_select "img.admin-boss-thumb[src*='placeholder'][alt^='A tall armoured boss']", 1, "a boss without a picture shows the built-in one"
    assert queries.any? { |sql| sql.include?('FROM "bosses"') }
    assert_empty queries.select { |sql| sql.include?("art_content") }, "no list query reads the picture bytes"
  end

  test "the list always offers to add next week's boss, and warns when no boss covers next week" do
    admin!
    travel_to(TODAY) { get "/admin/bosses" }
    assert_select "a.btn[href='/admin/bosses/new']", text: "Add next week's boss"
    assert_select ".admin-boss-notice[role=status]", text: /No boss is set for the week of Friday 27 November\. Add one\./
    assert_select ".admin-boss-notice a[href='/admin/bosses/new']", "Add one."

    create_boss
    travel_to(TODAY) { get "/admin/bosses" }
    assert_select ".admin-boss-notice", 0, "the next week is covered, so the warning goes away"
    assert_select "a.btn[href='/admin/bosses/new']", text: "Add next week's boss"
  end

  test "the warning stays quiet while the next uncovered week is more than 8 days away" do
    admin!
    travel_to(Time.utc(2026, 11, 17, 12)) { get "/admin/bosses" }
    assert_select ".admin-boss-notice", text: /No boss is set for the week of/, count: 0
    travel_to(Time.utc(2026, 11, 19, 12)) { get "/admin/bosses" }
    assert_select ".admin-boss-notice", text: /week of Friday 27 November/
  end

  test "the list says so when the week running now has no boss and can no longer be added" do
    admin!
    travel_to(Time.utc(2026, 11, 17, 12)) { get "/admin/bosses" } # Boss 0 ended Thursday 12th, Boss 2 starts Friday 20th: the week from 13 Nov has none
    assert_select ".admin-boss-notice[role=status]", text: /This week, from Friday 13 November, has no boss\..*can't be added here/m
    travel_to(Time.utc(2026, 11, 24, 12)) { get "/admin/bosses" }
    assert_select ".admin-boss-notice", text: /This week/, count: 0
  end

  test "a gap before a later boss is still warned about" do
    make_boss(starts_on: Date.new(2026, 12, 4), name: "Boss 4")
    admin!
    travel_to(TODAY) { get "/admin/bosses" }
    assert_select ".admin-boss-notice", text: /week of Friday 27 November/
  end

  test "the edit form shows the current picture, an alt field and a remove box only for an uploaded picture" do
    admin!
    travel_to(TODAY) { get "/admin/bosses/#{@boss.id}/edit" }
    assert_select "form[enctype='multipart/form-data'] input[name='boss[lock_version]']", 1
    assert_select "img.admin-boss-art[src*='placeholder']", 1
    assert_select "input[name='boss[remove_art]']", 0
    assert_select "input[name='boss[art_key]']", 0
    assert_select "input[name='boss[starts_on]']", 0

    give_art(@boss, alt: "A tall red boss")
    travel_to(TODAY) { get "/admin/bosses/#{@boss.id}/edit" }
    assert_select "img.admin-boss-art[alt='A tall red boss']", 1
    assert_select "input[type=checkbox][name='boss[remove_art]']", 1
    assert_select "input[name='boss[art_alt]'][value='A tall red boss']", 1
  end

  test "an admin replaces a boss's picture and alt text, and the audit row says a picture changed without naming anything" do
    give_art(@boss, alt: "Old words")
    old_sha = @boss.art_sha256
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { lock_version: @boss.lock_version, name: "Boss 2", art_upload: png_upload(solid(50, 25, [ 10, 200, 10 ]).pngsave_buffer, name: "new.png"), art_alt: "New words" } }
    end
    assert_redirected_to "/admin/bosses"
    @boss.reload
    assert_not_equal old_sha, @boss.art_sha256
    assert_equal [ 50, 25 ], [ @boss.art_width, @boss.art_height ]
    assert_equal "New words", @boss.art_alt
    event = audit_rows("boss_updated").sole
    assert_equal({ "boss_id" => @boss.id, "changed" => "art_alt picture" }, event.metadata)
    assert_not_includes event.metadata.to_json, "words"
  end

  test "replacing the picture without changing the alt text keeps the old alt text" do
    give_art(@boss, alt: "Kept words")
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Boss 2", art_alt: "Kept words", art_upload: png_upload(solid(50, 25).pngsave_buffer) } }
    end
    assert_equal "Kept words", @boss.reload.art_alt
    assert_equal [ 50, 25 ], [ @boss.art_width, @boss.art_height ]
  end

  test "an admin removes a boss's picture: back to the built-in one, alt text gone" do
    give_art(@boss)
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Boss 2", art_alt: "A tall red boss", remove_art: "1" } }
    end
    assert_redirected_to "/admin/bosses"
    @boss.reload
    assert_not @boss.art?
    assert_nil @boss.art_alt
    assert_nil Boss.art_content_for(@boss.id)
    assert_equal "bosses/placeholder.webp", @boss.art_path
    assert_includes audit_rows("boss_updated").sole.metadata["changed"], "picture"
  end

  test "a bad file on edit is a 422 and the old picture and every other field stay as they were" do
    give_art(@boss, alt: "Old words")
    before = Boss.art_content_for(@boss.id)
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Changed", hp_hours: "1", art_upload: upload_file("GIF89a-not-really", name: "x.gif", type: "image/gif"), art_alt: "x" } }
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", text: /The picture: /
    @boss.reload
    assert_equal "Boss 2", @boss.name
    assert_equal "Old words", @boss.art_alt
    assert_equal before, Boss.art_content_for(@boss.id)
    assert_empty audit_rows("boss_updated")
  end

  test "alt text can be edited on its own, and an uploaded picture cannot be left without it" do
    give_art(@boss, alt: "Old words")
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Boss 2", art_alt: "Better words" } }
      assert_redirected_to "/admin/bosses"
      assert_equal "Better words", @boss.reload.art_alt

      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Boss 2", art_alt: "" } }
      assert_response :unprocessable_content
      assert_select ".admin-form__errors li a[href='#boss_art_alt']"
      assert_equal "Better words", @boss.reload.art_alt
    end
  end

  test "a blank lock_version is treated like a stale one, not a 500" do
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Blank", lock_version: "" } }
      assert_redirected_to "/admin/bosses/#{@boss.id}/edit"
      assert_match(/Someone else changed/, flash[:alert])
    end
    assert_equal "Boss 2", @boss.reload.name
  end

  test "a failed save shows the stored picture, not the unsaved one, and says the chosen file was not kept" do
    give_art(@boss, alt: "Old words")
    stored_path = @boss.art_path
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "a" * 61, art_upload: png_upload(solid(50, 25, [ 10, 200, 10 ]).pngsave_buffer, name: "new.png"), art_alt: "New words" } }
    end
    assert_response :unprocessable_content
    assert_select "img.admin-boss-art[src=?][alt=?]", stored_path, "Old words"
    assert_select ".admin-form__hint", text: /An uploaded picture \(40 by 20 pixels\)/
    assert_select ".admin-form__errors li a[href='#boss_art_upload']", text: /was not kept\. Choose it again/
    assert_select "input#boss_remove_art", 1
  end

  test "a failed save for a boss with no picture does not show an uploaded one" do
    admin!
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Boss 2", art_upload: png_upload, art_alt: "" } }
    end
    assert_response :unprocessable_content
    assert_select "img.admin-boss-art[src*='placeholder']", 1
    assert_select ".admin-form__hint", text: /The built-in picture\./
    assert_select "input#boss_remove_art", 0
  end

  test "two admins editing the same boss: the second save is refused with a friendly message and the first change stays" do
    admin!
    stale = @boss.lock_version
    travel_to(Time.utc(2026, 11, 12, 12)) do
      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "First edit", lock_version: stale } }
      assert_redirected_to "/admin/bosses"

      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Second edit", lock_version: stale } }
      assert_redirected_to "/admin/bosses/#{@boss.id}/edit"
      assert_match(/Someone else changed First edit while you were editing/, flash[:alert])

      patch "/admin/bosses/#{@boss.id}", params: { boss: { name: "Absurd", lock_version: "99999999999999999999" } }
      assert_redirected_to "/admin/bosses/#{@boss.id}/edit"
    end
    assert_equal "First edit", @boss.reload.name
    assert_equal 1, audit_rows("boss_updated").size, "a refused save writes no audit row"
  end

  test "the staff-only parameters are filtered out of the logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("boss" => { "art_alt" => "Describes the boss", "art_upload" => "file", "art_content" => "bytes", "starts_on" => "2026-11-27" })["boss"]
    assert_equal "[FILTERED]", filtered["art_alt"]
    assert_equal "[FILTERED]", filtered["art_upload"]
    assert_equal "[FILTERED]", filtered["art_content"]
    assert_equal "2026-11-27", filtered["starts_on"], "the week is not secret and stays readable"
  end

  test "the admin routes for bosses are exactly index, new, create, edit and update, with no format suffix and no delete" do
    admin!
    get "/admin/bosses.json"
    assert_response :not_found
    delete "/admin/bosses/#{@boss.id}"
    assert_response :not_found
    assert Boss.exists?(@boss.id)
  end
end
