# Operator tools for the hours ledger (app/services/hours/**). They print counts only, never Slack ids or names.
namespace :hours do
  desc "Import Hackatime time from a CSV (slack_id,date,seconds[,project]); safe to repeat: hours:import[path/to/file.csv]"
  task :import, [ :path ] => :environment do |_task, args|
    source = Hackatime::CsvSource.new(args[:path])
    totals = source.users.find_each.reduce(Hours::Sync::Summary.empty) do |sum, user|
      sum + Hours::Sync.call(user, source: source, from: nil, to: nil)
    end
    puts "hours:import rows=#{source.row_count} invalid_rows=#{source.invalid_row_count} " \
         "unknown_slack_ids=#{source.unknown_slack_id_count} credited_seconds=#{totals.credited_seconds} " \
         "credited_days=#{totals.credited_days} unchanged_days=#{totals.unchanged_days} capped_days=#{totals.capped} " \
         "negative_skipped=#{totals.skipped_negative} rejected_days=#{totals.rejected}"
  rescue ArgumentError => error
    abort "hours:import failed: #{error.message}"
  end

  desc "Credit time by hand (source manual): hours:credit[slack_id,YYYY-MM-DD,seconds,note]. The same date, note and seconds give " \
       "one credit however often it runs (re-running is safe; change the note or the seconds to credit again)."
  task :credit, [ :slack_id, :date, :seconds, :note ] => :environment do |_task, args|
    user = args[:slack_id].present? ? User.find_by(slack_id: args[:slack_id]) : nil
    abort "hours:credit failed: no user with that Slack id" unless user

    note = [ args[:note], *args.extras ].compact.join(",").strip
    date = Date.iso8601(args[:date].to_s)
    seconds = Integer(args[:seconds].to_s, 10)
    result = Hours::Credit.call(user: user, seconds: seconds, source: "manual", local_date: date, note: note,
                                created_by: "rake:credit",
                                idempotency_key: "manual:#{date.iso8601}:#{Digest::SHA256.hexdigest(note)[0, 16]}:#{seconds}")
    puts "hours:credit status=#{result.status} credited_seconds=#{result.credited_seconds}"
  rescue Hours::Credit::Rejected, ArgumentError => error
    abort "hours:credit failed: #{error.message}"
  end
end
