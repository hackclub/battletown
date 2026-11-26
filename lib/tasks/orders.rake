namespace :orders do
  desc "Delete shipping addresses that are due (30 days after shipped or fulfilled; cancelled and refunded at once). Prints counts only"
  task purge_addresses: :environment do
    JobRun.record("orders:purge_addresses") do |run|
      run[:deleted] = Orders::PurgeAddresses.all
      puts "orders:purge_addresses deleted=#{run[:deleted]}"
    end
  end

  desc "Delete expired and used address offers (the short-lived lists of addresses from Hack Club Auth). Prints counts only"
  task purge_address_offers: :environment do
    JobRun.record("orders:purge_address_offers") do |run|
      run[:deleted] = Orders::PurgeAddresses.purge_offers
      puts "orders:purge_address_offers deleted=#{run[:deleted]}"
    end
  end
end
