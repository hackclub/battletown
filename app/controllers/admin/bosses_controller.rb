module Admin
  # The weekly bosses for staff (/admin/bosses): list, add next week's boss, and edit a boss's name, picture and health. A week
  # is Friday to Thursday and is chosen from the next free Fridays when a boss is added; dates are never editable afterwards.
  # Health is editable only until the boss starts (the Boss model refuses it afterwards, whatever the form says).
  #
  # A picture goes through the same safe re-encode as shop pictures (ShipImages::Processor with Bosses::ArtConfig) BEFORE anything
  # is saved: a file that cannot be used is a 422 with a plain reason and nothing is stored. The original upload is never kept.
  # "Use last week's picture" copies the latest boss's picture and alt text. Two admins saving the same boss at once are caught
  # by `lock_version`. Lists and edit pages never load picture bytes. Every change is recorded in the staff audit trail
  # (AdminAudit) in the same transaction, with ids and counts only: never a name or alt text.
  class BossesController < BaseController
    before_action :set_boss, only: %i[edit update]

    def index
      @bosses = Boss.without_art_content.chronological.to_a
      @today = Date.current
      @damage = @bosses.to_h { |boss| [ boss.id, Bosses::Damage.for(boss) ] }
      weeks = Bosses::FreeWeeks.new(@bosses, today: @today)
      @missing_week = weeks.missing_next
      @missing_current_week = weeks.missing_current
    end

    def new
      load_new_form
      @boss = Boss.new(starts_on: @weeks.default)
      @use_previous = true
    end

    def create
      load_new_form
      @boss = Boss.new(create_params.merge(art_key: Boss::ART_KEYS.first)) # the built-in picture, until one is uploaded
      @use_previous = use_previous?
      week_offered = @weeks.options.include?(@boss.starts_on) # not a past week, not years away (a stale or hand-made form)
      problem = apply_picture(creating: true)
      if problem.nil? && week_offered && save_boss { audit("boss_created", boss_id: @boss.id, hp_seconds: @boss.hp_seconds, picture: @boss.art?) }
        redirect_to admin_bosses_path, notice: "Added #{@boss.name}.", status: :see_other
      else
        report(problem)
        @boss.errors.add(:starts_on, "isn't one of the weeks on offer. Pick one from the list.") unless week_offered
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      raise ActiveRecord::StaleObjectError.new(@boss, "update") if update_params.key?(:lock_version) && update_params[:lock_version].blank?

      @boss.assign_attributes(update_params)
      problem = apply_picture(creating: false)
      if problem.nil? && save_boss { audit_update }
        redirect_to admin_bosses_path, notice: "Saved #{@boss.name}.", status: :see_other
      else
        report(problem)
        render :edit, status: :unprocessable_content
      end
    rescue ActiveRecord::StaleObjectError, ActiveModel::RangeError # an absurd lock_version cannot match the row either
      redirect_to edit_admin_boss_path(@boss), alert: "Someone else changed #{@boss.name_was} while you were editing. The form now shows their version: make your change again.", status: :see_other
    end

    private

    # Without the picture bytes: neither page needs them, and an upload replaces the column without reading it.
    def set_boss = @boss = Boss.without_art_content.find(params[:id])

    def update_params = params.expect(boss: %i[name hp_hours art_alt lock_version])

    def create_params = params.expect(boss: %i[name hp_hours starts_on art_alt])

    def load_new_form
      bosses = Boss.without_art_content.chronological.to_a
      @weeks = Bosses::FreeWeeks.new(bosses, today: Date.current)
      @previous = bosses.last if bosses.last&.art?
    end

    def use_previous?
      fields = params[:boss]
      fields.respond_to?(:key?) ? fields[:use_previous_art] == "1" : false
    end

    # The picture fields: a new upload replaces the picture; otherwise a new boss may copy the previous boss's, and an existing
    # one may be sent back to the built-in picture ("Remove the picture"). Alt text only describes an uploaded picture, so it is
    # dropped when there is none. Returns the reason in words when the upload cannot be used (nothing is saved then), else nil.
    def apply_picture(creating:)
      fields = params[:boss]
      return unless fields.respond_to?(:key?)

      upload = fields[:art_upload]
      if upload.present?
        return "That wasn't a file we could read." unless upload.respond_to?(:tempfile)

        @boss.attach_art(ShipImages::Processor.call(upload, config: Bosses::ArtConfig.current))
      elsif creating && @use_previous && @previous
        typed_alt = @boss.art_alt
        @boss.copy_art_from(@previous)
        @boss.art_alt = typed_alt if typed_alt.present?
      elsif !creating && fields[:remove_art] == "1"
        @boss.remove_art
      end
      @boss.art_alt = nil unless @boss.art?
      nil
    rescue ShipImages::Rejected => error
      error.message
    end

    # The picture is never kept across a failed save (a file input cannot be filled in again), so say so.
    def report(problem)
      @boss.valid?
      if problem
        @boss.errors.add(:base, "The picture: #{problem}", target: "boss_art_upload")
      elsif upload_chosen?
        @boss.errors.add(:base, "The picture you chose was not kept. Choose it again after fixing the above.", target: "boss_art_upload")
      end
    end

    def upload_chosen?
      fields = params[:boss]
      fields.respond_to?(:key?) && fields[:art_upload].present?
    end

    # Saves the boss and runs the block (which writes the audit row) in one transaction, so the change and its trail commit or
    # roll back together. False when the boss is invalid, or when another admin took the same week a moment ago (the database
    # refuses an overlap whatever the form says).
    def save_boss
      Boss.transaction do
        raise ActiveRecord::Rollback unless @boss.save

        yield
        true
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::ExclusionViolation
      @boss.errors.add(:base, "That week was just taken by another boss. Pick another week.", target: "boss_starts_on")
      false
    end

    # The audit row for an edit: which fields changed (names only, never their values).
    def audit_update
      changed = @boss.saved_changes.keys - %w[updated_at lock_version art_width art_height art_byte_size art_sha256]
      changed = changed.map { |name| name == "art_content" ? "picture" : name }
      audit("boss_updated", boss_id: @boss.id, **(changed.any? ? { changed: changed.join(" ") } : {}))
    end

    # Ids, numbers and field names only: never a boss name or alt text.
    def audit(action, **metadata)
      AdminAudit.record!(actor: current_user, action: action, subject: @boss, metadata: metadata)
    end
  end
end
