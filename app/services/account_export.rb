# Everything we store about one person, as a plain Hash ready for JSON. Always built from the
# user it is given (the controller passes current_user, never a client-supplied id).
class AccountExport
  FORMAT_VERSION = 1

  def initialize(user, now: Time.current)
    @user = user
    @now = now
  end

  def as_json(*)
    {
      "battletown_data_export" => {
        "format_version" => FORMAT_VERSION,
        "exported_at" => @now.utc.iso8601,
        "about" => "Everything Battletown stores about your account. Your phone number, birthdate and address are " \
                   "requested from Hack Club Auth when you sign in but are not stored, so they are not here."
      },
      "data" => AccountData.sources.to_h { |source| [ source.key, rows_for(source) ] }
    }
  end

  def to_json(*) = JSON.pretty_generate(as_json)

  private

  def rows_for(source)
    records = source.records_for(@user).order(source.model.primary_key).to_a
    rows = records.map { |record| row(source, record) }
    source.table == "users" ? rows.first : rows
  end

  def row(source, record)
    omit = Array(source.except) + AccountData::NEVER_EXPORT
    attributes = record.attributes.except(*omit).transform_values { |v| v.respond_to?(:iso8601) ? v.utc.iso8601 : v }
    attributes = source.decorate.call(attributes, record) if source.decorate
    attributes.except(*AccountData::NEVER_EXPORT)
  end
end
