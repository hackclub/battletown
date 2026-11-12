# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :code, :state, :id_token, :access_token, :client_secret, :phone, :birthdate, :address,
  :street, :locality, :region, :postal, :zip,
  :project_idea, :idea, :repo_url, :demo_url, :hackatime_project, "project.name", :display_name, :slack_id, :time_zone, :coding_time, :coding_day_names, :prize_key, :referral_source,
  # Exactly `name`: project names are free text, and this also hides the database logger's bind values at debug level.
  /\Aname\z/,
  # The staff search boxes (users: a display name, Slack id, Hack Club Auth id or email; projects: a name or repo fragment) go in
  # `q`; the Hack Club Auth id column appears as a bound SQL value too; `details` is the flag details free text.
  /\Aq\z/, :hca_uid, :details,
  :note, :idempotency_key, :description, :reason, :comment,
  # Staff-written text stored with an audit event (`metadata`, a JSON object with the reason) and in a private staff note (`body`): keep both out of the SQL log's bind values.
  :metadata, /\Abody\z/,
  # Screenshot uploads: an uploaded file's log line would carry its original file name (often a real name); the alt text is free text.
  :images
]
