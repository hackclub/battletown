module Projects
  # The short "link your Hackatime projects" flow: rename the project (optional) and link one or more Hackatime projects by
  # their exact names, in one step, all or nothing. The long edit page stays for everything else.
  #
  #   result = Projects::LinkHackatime.call(project: project, user: user, project_name: "Space Farm", hackatime_names: %w[space-farm])
  #   result.ok?     # => true when the rename and every link are saved
  #   result.error   # => a sentence for the person when not
  #   result.links   # => the links made
  class LinkHackatime
    Result = Data.define(:ok, :error, :links) do
      def ok? = ok
    end

    def self.call(**args) = new(**args).call

    # The sentence shown for a link that did not save (also used by the long edit page's link form).
    def self.error_message(link, name, user)
      return "Type the name of the Hackatime project to link." if name.blank?

      # The uniqueness error carries a custom message, so ask the table instead of the error's type.
      other = HackatimeLink.project_for(user, name)
      return "#{name} is already linked to #{other.name}. Unlink it there first." if other

      "Couldn't link that: #{link.errors.full_messages.to_sentence}."
    end

    def initialize(project:, user:, project_name:, hackatime_names:)
      @project = project
      @user = user
      @project_name = project_name
      @names = Array(hackatime_names).map { |name| name.to_s.strip }.reject(&:empty?).uniq
    end

    def call
      @project.name = @project_name if @project_name.present? # not saved here: only so a failed save shows what was typed
      return failure("Add at least one Hackatime project to link.") if @names.empty?

      # Not built through the association, so the project's own validation does not trip over the links'.
      links = @names.map { |name| HackatimeLink.new(project: @project, user: @user, hackatime_project: name, link_method: "manual") }
      bad = links.find { |link| !link.valid? }
      return failure(self.class.error_message(bad, bad.hackatime_project, @user)) if bad
      return failure(@project.errors.full_messages.to_sentence) unless @project.valid?

      Project.transaction do
        @project.save!
        links.each(&:save!)
        # A pending question about one of these names is answered by choosing it yourself.
        @project.link_suggestions.pending.where(hackatime_project: @names).update_all(state: "accepted", updated_at: Time.current)
      end
      Result.new(ok: true, error: nil, links: links)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      failure(e.respond_to?(:record) && e.record.is_a?(HackatimeLink) ? self.class.error_message(e.record, e.record.hackatime_project, @user) : "Couldn't link that. Please try again.")
    end

    private

    def failure(message) = Result.new(ok: false, error: message, links: [])
  end
end
