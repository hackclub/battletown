# Operator tools for the weekly boss (app/services/bosses/**).
namespace :bosses do
  desc "Create the four launch bosses (Friday 2026-11-13 onwards) if they are missing; never changes an existing boss"
  task seed: :environment do
    puts "bosses:seed created=#{Bosses::Seed.call} total=#{Boss.count}"
  end
end
