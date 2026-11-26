namespace :privacy do
  desc "Delete used data-deletion token ids older than 7 days (they are also purged as requests arrive)"
  task purge_tokens: :environment do
    JobRun.record("privacy:purge_tokens") do |run|
      run[:deleted] = PrivacyRequestToken.purge_expired
      puts "privacy:purge_tokens deleted=#{run[:deleted]}"
    end
  end
end
