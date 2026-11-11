# Who is an admin: the Hack Club Auth ids (`sub`, stored as users.hca_uid) listed in the comma-separated
# ADMIN_HCA_UIDS environment variable. Read at call time and never cached, so a change takes effect on the next
# request/deploy. Exact, case-sensitive match only (no substring or prefix match); absent or empty means nobody.
class AdminAllowlist
  ENV_KEY = "ADMIN_HCA_UIDS".freeze

  def self.uids(raw = ENV[ENV_KEY])
    raw.to_s.split(",").map(&:strip).reject(&:empty?).uniq
  end

  def self.include?(uid)
    uid = uid.to_s
    uid.present? && uids.include?(uid)
  end
end
