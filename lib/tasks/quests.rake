namespace :quests do
  desc "Record finished weekly quests for every onboarded user and pay the rewards that are waiting on an approved ship (idempotent; safe to run hourly). Does nothing while the quests flag is off. Exits 1 if any user failed"
  task evaluate: :environment do
    JobRun.record("quests:evaluate") do |run|
      if Features.enabled?(:quests)
        counts = Quests::Evaluate.all
        run.merge!(counts)
        puts "quests:evaluate users=#{counts[:users]} completions=#{counts[:completions]} errors=#{counts[:errors]}"
        exit 1 if counts[:errors].positive?
      else
        run[:skipped] = 1
        puts "quests:evaluate skipped (the quests flag is off)"
      end
    end
  end
end
