# Enforced CSP. Scripts and styles are nonce-based (importmap/Turbo use the nonce automatically),
# so inline <script>/<style> blocks need `nonce: true` and style="" attributes are not allowed.
# form-action includes the Hack Club Auth host because browsers enforce it on redirects after a form POST.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self
    policy.img_src :self, :data
    policy.font_src :self
    policy.media_src :self
    policy.connect_src :self
    policy.object_src :none
    policy.base_uri :self
    policy.frame_ancestors :none
    # Chrome also checks redirects after a form POST against form-action: the "Connect" buttons POST to this app,
    # which redirects to Hack Club Auth or Hackatime, so both origins must be listed.
    policy.form_action :self, Rails.configuration.x.hca.issuer, Rails.configuration.x.hackatime.base_url
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
