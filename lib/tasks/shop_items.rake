# Operator tools for the shop catalogue (app/services/shop_items/**).
namespace :shop_items do
  desc "Add the default items from config/prizes.yml that are missing from the shop; never changes an existing item"
  task import: :environment do
    puts "shop_items:import added=#{ShopItems::Seed.call} total=#{ShopItem.count}"
  end
end
