# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :code, :state, :id_token, :access_token, :client_secret, :phone, :birthdate, :address,
  :street, :locality, :region, :postal, :zip,
  :project_idea, :idea, :repo_url, :demo_url, :hackatime_project, "project.name", :display_name, :slack_id, :time_zone, :coding_time, :coding_day_names, :prize_key, :referral_source,
  # Exactly `name`: project names are free text, and this also hides the database logger's bind values at debug level.
  /\Aname\z/,
  :note, :idempotency_key, :description, :reason, :comment
]
