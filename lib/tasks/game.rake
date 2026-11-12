namespace :game do
  desc "Settle every user's finished local days into daily_results (idempotent; safe to run hourly)"
  task settle: :environment do
    counts = Game::Settle.all
    puts "game:settle users=#{counts[:users]} days_written=#{counts[:days]} errors=#{counts[:errors]}"
  end
end
