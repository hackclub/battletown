module AdminUsers
  # What hours and coin adjustments have in common: who may do it, the typed reason, the one-time token that makes a repeated
  # submit harmless, and the way a failed check is reported. A form object: build it from the request, ask `valid?` for the
  # confirm page (errors are friendly sentences), and `apply!` to do it. Nothing here edits history: both subclasses add a NEW
  # ledger entry and an audit event in one transaction, under the person's row lock.
  class Adjustment
    include ActiveModel::Model
    include ActiveModel::Attributes

    DIRECTIONS = %w[add subtract].freeze
    REASON_RANGE = 5..200
    TOKEN_FORMAT = /\A[0-9a-f]{32}\z/
    OWN_ACCOUNT_MESSAGE = "You can't change your own hours or coins. Ask another staff member to do it.".freeze

    # status: :applied (written now) or :duplicate (this token was already used; nothing new was written).
    Outcome = Data.define(:status, :record) do
      def duplicate? = status == :duplicate
    end

    class Invalid < StandardError
      attr_reader :adjustment

      def initialize(adjustment)
        @adjustment = adjustment
        super(adjustment.errors.full_messages.to_sentence)
      end
    end

    attribute :direction, :string
    attribute :reason, :string
    attribute :token, :string

    attr_reader :staff, :user

    validate :not_own_account
    validates :direction, inclusion: { in: DIRECTIONS, message: "must be add or subtract" }
    validate :reason_is_usable
    validates :token, format: { with: TOKEN_FORMAT, message: "is missing; reload the page and try again" }

    # A fresh token for a form. The same token submitted twice changes the ledger once.
    def self.new_token = SecureRandom.hex(16)

    def initialize(staff:, user:, **attributes)
      super(**attributes)
      @staff = staff
      @user = user
    end

    def reason=(value)
      super(value.to_s.delete("\u0000").gsub(/\s+/, " ").strip)
    end

    def add? = direction == "add"

    def sign = add? ? 1 : -1

    def idempotency_key = "admin_adjust:#{token}"

    def created_by = "admin:#{staff.id}"

    # Does it, once. Runs under the person's row lock; a token already used returns the earlier result untouched.
    def apply!
      user.with_lock do
        existing = token.to_s.match?(TOKEN_FORMAT) ? existing_record : nil
        next Outcome.new(status: :duplicate, record: existing) if existing

        raise Invalid, self unless valid?

        Outcome.new(status: :applied, record: write!)
      end
    end

    private

    def not_own_account = (errors.add(:base, OWN_ACCOUNT_MESSAGE) if staff.id == user.id)

    def reason_is_usable
      if reason.blank?
        errors.add(:reason, "is needed (#{REASON_RANGE.min} to #{REASON_RANGE.max} characters)")
      elsif !REASON_RANGE.cover?(reason.length)
        errors.add(:reason, "must be #{REASON_RANGE.min} to #{REASON_RANGE.max} characters (it is #{reason.length})")
      elsif reason.match?(AdminAudit::Metadata::EMAIL) || reason.match?(AdminAudit::Metadata::PHONE)
        errors.add(:reason, "must not contain an email address or phone number; say what happened without them")
      end
    end
  end
end
