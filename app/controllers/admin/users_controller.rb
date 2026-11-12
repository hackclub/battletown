module Admin
  # Staff user management: a searchable list (/admin/users) and one person's page (/admin/users/:id). Read-only here; the
  # changes staff can make (an hours or coin adjustment, a private note) have their own controllers. Staff cannot edit
  # verification or eligibility (they come from Hack Club Auth), delete, impersonate or act in bulk.
  #
  # The list never shows an email, Slack id or Hack Club Auth id (they can be searched, exactly); the search text is a GET
  # parameter `q` that the request log filters out. The person's page does show them, and each view is written to the audit
  # trail (at most once per staff member and person in ten minutes).
  class UsersController < BaseController
    def index
      @result = AdminUsers::Directory.call(params)
      @referrals = Referral.all
    end

    def show
      @user = User.find(params[:id])
      AdminAudit.record_once!(actor: current_user, action: "user_viewed", subject: @user, within: AdminUsers::Config.current.view_audit_window)
      @profile = AdminUsers::Profile.new(@user)
    end
  end
end
