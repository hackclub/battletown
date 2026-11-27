namespace :returning do
  desc "Settle everyone's finished days so welcome-back windows are opened and boosted (needs the `returning` flag; idempotent, same work as game:settle)"
  task evaluate: :environment do
    unless Features.enabled?(:returning)
      puts "returning:evaluate flag_off=true"
      next
    end

    before = WelcomeBackWindow.count
    counts = Game::Settle.all
    puts "returning:evaluate users=#{counts[:users]} days_written=#{counts[:days]} windows_opened=#{WelcomeBackWindow.count - before} errors=#{counts[:errors]}"
    exit 1 if counts[:errors].positive?
  end
end
