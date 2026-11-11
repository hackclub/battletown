namespace :privacy do
  desc "Delete used data-deletion token ids older than 7 days (they are also purged as requests arrive)"
  task purge_tokens: :environment do
    puts "privacy:purge_tokens deleted=#{PrivacyRequestToken.purge_expired}"
  end
end
