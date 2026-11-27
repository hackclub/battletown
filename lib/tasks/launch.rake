namespace :launch do
  desc "Lists what must be set before full launch; exits non-zero while anything is missing"
  task check: :environment do
    problems = []
    problems << "program end date not set (onboarding.program_ends_on in config/game.yml)" unless Onboarding::DailyTime.real_date?
    if problems.empty?
      puts "launch:check ok"
    else
      problems.each { |problem| warn "launch:check: #{problem}" }
      exit 1
    end
  end
end
