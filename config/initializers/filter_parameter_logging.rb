# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :code, :state, :id_token, :access_token, :client_secret, :phone, :birthdate, :address,
  :street, :locality, :region, :postal, :zip,
  :project_idea, :display_name, :slack_id, :time_zone, :coding_time, :coding_day_names, :prize_key, :referral_source,
  :note, :idempotency_key
]
