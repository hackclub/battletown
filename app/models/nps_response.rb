# One answer to the NPS survey (feature flag `nps`, see app/services/nps/**): a 0 to 10 score and an optional short
# comment. One per person per prompt window (unique index). The comment is free text from a teen, so it can hold personal
# data: plain text only, at most COMMENT_MAX characters, shown to staff only and emptied by `bin/rails nps:prune` after
# `nps.comment_retention_days`. Deleted with the user (ON DELETE CASCADE).
class NpsResponse < ApplicationRecord
  SCORES = (0..10).freeze
  COMMENT_MAX = 300 # mirrors the nps_responses_comment_length_check constraint

  belongs_to :user

  validates :score, inclusion: { in: SCORES }, numericality: { only_integer: true }
  validates :comment, length: { maximum: COMMENT_MAX }, allow_nil: true
  validates :answered_at, :prompt_window_date, presence: true
  validates :prompt_window_date, uniqueness: { scope: :user_id }
  validate :comment_is_plain_text

  scope :newest_first, -> { order(answered_at: :desc, id: :desc) }
  scope :with_comment, -> { where.not(comment: nil) }

  # Typed text becomes the stored comment: no control characters (a newline becomes a space), one space between words,
  # nil when nothing is left. Escaping happens where it is shown (ERB); nothing here treats it as HTML.
  def self.clean_comment(text)
    cleaned = text.to_s.gsub(/[[:cntrl:]]/, " ").squish
    cleaned.presence
  end

  private

  def comment_is_plain_text
    errors.add(:comment, "can only be plain text") if comment&.match?(/[[:cntrl:]]/)
  end
end
