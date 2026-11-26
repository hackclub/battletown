require "vips"

module DevSimulator
  # What a simulated player looks like on the stage and on their profile, so a local demo reads like the real thing: a believable
  # first name or handle and their own picture, instead of "Brave Otter" and a coloured initial. Development only (the simulator
  # refuses a database that is not on this machine) and it never calls Slack: the picture goes through the same pipeline a Slack picture
  # does (SlackProfiles::Avatar: found by its bytes, re-encoded to a small WebP, metadata stripped) and is stored as the player's
  # slack_profiles row, status "ok", so everything downstream (the avatar route, the fighters, the profile page) is the real code path.
  #
  # The pictures are drawn locally with libvips (a symmetric 5 x 5 pattern in a colour of its own on a pale ground, like the
  # generated avatars of a code host) into tmp/dev_avatars/sim-N.png, once; a file already there is reused, so you can replace one with
  # a picture of your own. Pictures of your own put in tmp/dev_avatars/custom/ (png, jpg, webp or gif) are used first, in file name order.
  module Looks
    # First names and handles, all of them valid profile names (letters, numbers, spaces and . _ ' - only; nothing that reads as
    # an address). Two and a half dozen would repeat in a demo of twenty, so this is a long list and the pick is by counter.
    NAMES = %w[
      Maya Kai Priya Tomasz Zoe Arjun Lena Mateo Ife Sofia Noah Hana Leo Amara Ravi Chloe Jun Isla Omar Yuki
      Ella Dev Nora Finn Aisha Theo Sana Milo Ines Kofi Mira Ezra Anika Luca Tess Rohan Ada Idris Wren Bao
      mia_makes pixel_pip tom-codes nova.k_ cyber_sam byteme_ana ro_ro_dev Jax_ Lila_b Max_ship sunny_sh Ollie
      Zara_ Emre Dani Fatima Hugo Imani Jonas Keira
    ].freeze
    SUFFIXES = %w[K J M R S T B P N].freeze
    CUSTOM_DIR = "custom".freeze

    module_function

    # The profile name of simulated player `counter` (1, 2, 3...): a different one for each of up to 500 players.
    def name_for(counter)
      index = counter - 1
      base = NAMES[index % NAMES.size]
      round = index / NAMES.size
      round.zero? ? base : "#{base} #{SUFFIXES[(round - 1) % SUFFIXES.size]}"
    end

    # Gives the player their Slack-style profile (name and picture) as a stored copy. Safe to run again: it replaces the same row.
    # When a local manifest of real Slack members exists (SlackManifest), players 1..N wear its entries in order, one person each
    # (so no real name is shown twice); the players after the last entry, and every player when there is no manifest or a picture in it
    # cannot be read, keep the generated name and picture (and a generated name that equals a real one is changed). The stored row never
    # holds a Slack id: the user's slack_id stays nil, so no refresh ever asks Slack about a simulated player.
    def apply(user, counter, entries: SlackManifest.entries)
      DevSimulator.check_local_database!
      entry = entries[counter - 1]
      picture = manifest_picture(entry) if entry
      entry = nil unless picture
      picture ||= SlackProfiles::Avatar.call(File.binread(picture_path(counter)))
      name = entry ? entry.profile_name : generated_name(counter, entries)
      user.update!(profile_name: name)
      SlackProfile.find_or_initialize_by(user_id: user.id).update!(
        use_name: true, use_picture: true, display_name: entry ? entry.name : name, picture: picture.content, picture_sha256: picture.sha256,
        picture_bytes: picture.byte_size, status: "ok", failure_count: 0, fetched_at: Time.current, next_attempt_at: nil
      )
    end

    # True when this player already wears what `apply` would give them (a run that finds it true leaves the row alone).
    def current?(user, counter, entries: SlackManifest.entries)
      profile = SlackProfile.for(user)
      return false unless profile&.picture?

      entry = entries[counter - 1]
      return user.profile_name == entry.profile_name && profile.display_name == entry.name if entry

      entries.none? { |other| other.profile_name.casecmp?(user.profile_name.to_s) }
    end

    # Puts every simulated player already in the database into the look they should have now (the manifest's real names and pictures
    # after it was made or re-sampled; with no manifest nothing changes, a reset clears the players). `force` redoes players that already look right (a new picture
    # under the same name). Returns how many players were updated.
    def apply_all(force: false)
      DevSimulator.check_local_database!
      entries = SlackManifest.entries
      DevSimulator.players.order(:id).to_a.count do |player|
        counter = player.hca_uid.delete_prefix(UID_PREFIX).to_i
        next false unless counter.positive?
        next false unless force || !current?(player, counter, entries: entries)

        apply(player, counter, entries: entries)
        true
      end
    end

    # The profile name of player `counter` before `apply` runs: the manifest entry's, else the generated one.
    def profile_name_for(counter, entries: SlackManifest.entries)
      entries[counter - 1]&.profile_name || generated_name(counter, entries)
    end

    # A generated name that no real (manifest) name already uses.
    def generated_name(counter, entries)
      taken = entries.map { |entry| entry.profile_name.downcase }
      [ name_for(counter), name_for(counter + 1000), "#{name_for(counter)} #{counter}" ].find { |name| taken.exclude?(name.downcase) }
    end

    # The processed picture of a manifest entry, or nil when its file cannot be used (then the generated picture is used).
    def manifest_picture(entry)
      SlackProfiles::Avatar.call(File.binread(entry.picture_path))
    rescue SlackProfiles::Avatar::Rejected, SystemCallError
      nil
    end

    # The file for this player: one of the pictures of your own when there are any, else the generated one (made on first use).
    def picture_path(counter)
      custom = Dir.glob(directory.join(CUSTOM_DIR, "*.{png,jpg,jpeg,webp,gif}")).sort
      return custom[(counter - 1) % custom.size] if custom.any?

      path = directory.join("sim-#{counter}.png")
      generate(counter, path) unless path.exist?
      path.to_s
    end

    def directory = Rails.root.join("tmp", "dev_avatars").tap { |dir| FileUtils.mkdir_p(dir) }

    # A 256 px symmetric pattern, the same for the same counter.
    def generate(counter, path)
      random = Random.new(counter * 7919)
      hue = random.rand(360)
      foreground = rgb(hue, 0.62, 0.42)
      background = rgb((hue + random.rand(60..300)) % 360, 0.5, 0.9)
      cells = Array.new(5) { |_row| half = Array.new(3) { random.rand < 0.55 }; half + half[0, 2].reverse }
      cells[2][2] = true if cells.flatten.none?
      pixels = cells.flatten.flat_map { |on| on ? foreground : background }
      small = Vips::Image.new_from_memory(pixels.pack("C*"), 5, 5, 3, :uchar)
      small.resize(44.0, kernel: :nearest).embed(18, 18, 256, 256, extend: :background, background: background).write_to_file(path.to_s)
    end

    # HSL to [r, g, b] bytes.
    def rgb(hue, saturation, lightness)
      chroma = (1 - (2 * lightness - 1).abs) * saturation
      x = chroma * (1 - ((hue / 60.0) % 2 - 1).abs)
      r, g, b = case hue / 60
      when 0 then [ chroma, x, 0 ]
      when 1 then [ x, chroma, 0 ]
      when 2 then [ 0, chroma, x ]
      when 3 then [ 0, x, chroma ]
      when 4 then [ x, 0, chroma ]
      else [ chroma, 0, x ]
      end
      shift = lightness - chroma / 2
      [ r, g, b ].map { |value| ((value + shift) * 255).round.clamp(0, 255) }
    end
    private_class_method :generate, :rgb, :manifest_picture
  end
end
