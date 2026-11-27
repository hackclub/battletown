namespace :game do
  desc "Settle every user's finished local days into daily_results (idempotent; safe to run hourly). Exits 1 if any user failed"
  task settle: :environment do
    counts = Game::Settle.all
    puts "game:settle users=#{counts[:users]} days_written=#{counts[:days]} errors=#{counts[:errors]}"
    # Everyone was tried first; a non-zero exit makes a scheduled run show the failure (the next run retries them).
    exit 1 if counts[:errors].positive?
  end
end
