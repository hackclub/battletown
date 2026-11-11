module Privacy
  # Finds the users a verified token is about, from the token's subject only: emails (compared case-insensitively
  # with users.email), the Slack id (users.slack_id) and the Hack Club Auth identity id (users.hca_uid, the OIDC
  # `sub`, shaped `ident!...`). A user matching any one of them is part of the subject. Blank values never match,
  # so an empty subject finds nobody.
  class SubjectFinder
    def initialize(subject)
      @subject = subject
    end

    def user_ids
      conditions = []
      conditions << User.where("lower(email) IN (?)", @subject.emails) if @subject.emails.any?
      conditions << User.where(slack_id: @subject.slack_id) if @subject.slack_id.present?
      conditions << User.where(hca_uid: @subject.identity_id) if @subject.identity_id.present?
      return [] if conditions.empty?

      conditions.reduce(:or).order(:id).pluck(:id)
    end
  end
end
