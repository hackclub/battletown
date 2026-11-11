# Deletes a person. Only the user row is deleted here: every table that belongs to a user has a
# foreign key with ON DELETE CASCADE (enforced by test/models/account_data_test.rb), so the database
# removes the rest in the same transaction.
class AccountDeletion
  class Failed < StandardError; end

  def self.call(user) = new(user).call

  def initialize(user)
    @user = user
  end

  def call
    User.transaction do
      deleted = User.where(id: @user.id).delete_all
      raise Failed, "user row was not deleted" unless deleted == 1
    end
    # No email, name or ids in the log: the event only.
    Rails.logger.info("Account deleted")
    true
  end
end
