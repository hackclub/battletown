module Admin
  # The weekly quests (flag `quests`; a 404 while it is off, like every admin route for non-admins). Staff pick one goal
  # from the fixed menu, its number and the reward for a boss week. A quest can be changed until its week starts (the
  # Quest model refuses it afterwards whatever the form says), and its week is fixed. The list shows aggregates only:
  # how many people finished each quest and how many coins it has paid, never who.
  class QuestsController < BaseController
    before_action { require_feature!(:quests) }
    before_action :set_quest, only: %i[edit update]

    def index
      @quests = Quest.newest_first.to_a
      @stats = Quest.stats(@quests)
      @today = Date.current
    end

    def new
      config = Quests::Config.current
      first = config.menu.first
      @quest = Quest.new(goal_key: first.key, reward_coins: config.default_reward_coins)
      @quest.target = first.default_target
    end

    def create
      @quest = Quest.new(create_params)
      if @quest.save
        redirect_to admin_quests_path, notice: "Saved the quest for the week of #{@quest.starts_on.strftime('%-d %B')}."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @quest.update(update_params)
        redirect_to admin_quests_path, notice: "Saved the quest for the week of #{@quest.starts_on.strftime('%-d %B')}."
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def set_quest = @quest = Quest.find(params[:id])

    def create_params = params.expect(quest: %i[starts_on goal_key target reward_coins])

    # The week never changes after saving.
    def update_params = params.expect(quest: %i[goal_key target reward_coins])
  end
end
