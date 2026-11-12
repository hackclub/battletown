module Admin
  # List the weekly bosses and edit a boss's name, art and health. Dates are never editable (a week is a week), and
  # health is editable only until the boss starts (the Boss model refuses it afterwards, whatever the form says).
  class BossesController < BaseController
    before_action :set_boss, only: %i[edit update]

    def index
      @bosses = Boss.chronological.to_a
      @today = Date.current
      @damage = @bosses.to_h { |boss| [ boss.id, Bosses::Damage.for(boss) ] }
    end

    def edit; end

    def update
      saved = ActiveRecord::Base.transaction do
        @boss.update(boss_params).tap { |ok| AdminAudit.record!(actor: current_user, action: "boss_updated", subject: @boss, metadata: { boss_id: @boss.id }) if ok }
      end
      if saved
        redirect_to admin_bosses_path, notice: "Saved #{@boss.name}."
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def set_boss = @boss = Boss.find(params[:id])

    def boss_params = params.expect(boss: %i[name art_key hp_hours])
  end
end
