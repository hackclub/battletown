namespace :returning do
  desc "Settle everyone's finished days so welcome-back windows are opened and boosted (needs the `returning` flag; idempotent, same work as game:settle)"
  task evaluate: :environment do
    JobRun.record("returning:evaluate") do |run|
      unless Features.enabled?(:returning)
        run[:skipped] = 1
        puts "returning:evaluate flag_off=true"
        next
      end

      before = WelcomeBackWindow.count
      counts = Game::Settle.all
      run.merge!(counts.merge(windows_opened: WelcomeBackWindow.count - before))
      puts "returning:evaluate users=#{counts[:users]} days_written=#{counts[:days]} windows_opened=#{WelcomeBackWindow.count - before} errors=#{counts[:errors]}"
      exit 1 if counts[:errors].positive?
    end
  end
end
