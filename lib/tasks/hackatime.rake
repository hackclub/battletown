# Live Hackatime sync for users who linked their account at /hackatime (app/services/hackatime/http_source.rb).
# Prints counts only, never ids, names or tokens. Safe to repeat: Hours::Sync only credits differences. A no-op that
# exits 0 unless the hours source (HOURS_SOURCE, else config/game.yml) is http.
namespace :hackatime do
  desc "Credit recent Hackatime time for linked users: hackatime:sync[all] or hackatime:sync[<user id>]"
  task :sync, [ :target ] => :environment do |_task, args|
    target = args[:target].to_s.strip
    abort "hackatime:sync failed: pass all or a user id, e.g. hackatime:sync[all]" if target.empty?

    JobRun.record("hackatime:sync") do |run|
      # Same setting as the rest of the app (Hackatime.source): never call Hackatime unless live hours are switched on.
      source_name = Hackatime.source_name
      if source_name != "http"
        puts "hackatime:sync skipped: the hours source is #{source_name}, not http (set HOURS_SOURCE=http to sync)"
        next
      end

      users = User.where(id: HackatimeConnection.where(needs_reconnect: false).select(:user_id))
      users = users.where(id: Integer(target, 10)) unless target == "all"

      source = Hackatime::HttpSource.new
      counts = Hash.new(0)
      credited = Hours::Sync::Summary.empty
      users.find_each do |user|
        credited += Hours::Sync.call(user, source: source)
        counts[:synced] += 1
      rescue Hackatime::Client::AuthError
        counts[:needs_reconnect] += 1
      rescue Hackatime::Client::RetryableError, Hackatime::Client::ResponseError
        counts[:retry_later] += 1
      end

      # This process ends now: send the boss stage's last update (its in-process timer would never fire) before it does.
      Bosses::Live.flush_pending

      run.merge!(counts)
      run.merge!(credited_seconds: credited.credited_seconds, credited_days: credited.credited_days, unchanged_days: credited.unchanged_days,
                 capped_days: credited.capped, rejected_days: credited.rejected)
      puts "hackatime:sync users=#{counts[:synced]} needs_reconnect=#{counts[:needs_reconnect]} retry_later=#{counts[:retry_later]} " \
           "credited_seconds=#{credited.credited_seconds} credited_days=#{credited.credited_days} " \
           "unchanged_days=#{credited.unchanged_days} capped_days=#{credited.capped} rejected_days=#{credited.rejected}"
    end
  rescue ArgumentError => error
    abort "hackatime:sync failed: #{error.message}"
  end
end
