namespace :orders do
  desc "Delete shipping addresses that are due (30 days after shipped or fulfilled; cancelled and refunded at once). Prints counts only"
  task purge_addresses: :environment do
    puts "orders:purge_addresses deleted=#{Orders::PurgeAddresses.all}"
  end

  desc "Delete expired and used address offers (the short-lived lists of addresses from Hack Club Auth). Prints counts only"
  task purge_address_offers: :environment do
    puts "orders:purge_address_offers deleted=#{Orders::PurgeAddresses.purge_offers}"
  end
end
