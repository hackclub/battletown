module Projects
  # Connects a user's projects to Hackatime projects, only when it is safe.
  #
  #   Projects::AutoLinker.call(user, [ { name: "my-game", repo_url: "https://github.com/octo/my-game.git" } ])
  #
  # `candidates` is the list of the user's Hackatime projects (where it comes from is another task): hashes with a
  # `name:` and an optional `repo_url:` (string or symbol keys).
  #
  # 1. Certain: the candidate's GitHub repo URL, normalised (Projects::RepoUrl), equals exactly one live project's
  #    repo_url. It is linked at once (link_method "auto_repo"). Two projects sharing a repo is ambiguous: no link.
  # 2. Probably: no repo match, but the candidate's name is close to exactly one live project's name (same after
  #    lowercasing and dropping punctuation, or one contains the other, shorter side at least MIN_NAME_CHARS). That
  #    makes a PENDING suggestion and fires "project_link_suggested.battletown" (see Projects::LinkSuggestions). It
  #    is never linked without an explicit accept.
  #
  # Skipped: Hackatime projects already linked to any of the user's projects, suggestions already asked (pending,
  # accepted or declined: a "no" is remembered for good, and unlinking also counts as a "no"), archived projects, and
  # invalid names. Safe to call again with the same candidates.
  class AutoLinker
    MIN_NAME_CHARS = 4

    Result = Data.define(:linked, :suggested)

    def self.call(user, candidates, projects: nil) = new(user, projects: projects).call(candidates)

    def initialize(user, projects: nil)
      @user = user
      @projects = (projects || user.projects.live).select { |project| project.user_id == user.id && project.status_active? }
    end

    def call(candidates)
      linked = []
      suggested = []
      linked_names = @user.hackatime_links.pluck(:hackatime_project).to_set

      normalize_candidates(candidates).each do |candidate|
        next if linked_names.include?(candidate[:name])

        if (project = repo_match(candidate))
          link = link_by_repo(project, candidate[:name])
          if link
            linked << link
            linked_names << candidate[:name]
          end
        elsif !repo_ambiguous?(candidate) && (project = name_match(candidate))
          suggestion = LinkSuggestions.suggest!(project, candidate[:name])
          suggested << suggestion if suggestion
        end
      end

      Result.new(linked: linked, suggested: suggested)
    end

    # Lowercase, letters and digits only: "My-Game_2" and "my game 2" both become "mygame2".
    def self.name_key(text) = text.to_s.downcase.gsub(/[^\p{L}\p{N}]/, "")

    def self.close_names?(first, second)
      a = name_key(first)
      b = name_key(second)
      return false if [ a.length, b.length ].min < MIN_NAME_CHARS

      a == b || a.include?(b) || b.include?(a)
    end

    private

    def normalize_candidates(candidates)
      Array(candidates).filter_map do |candidate|
        data = candidate.respond_to?(:to_h) ? candidate.to_h.symbolize_keys : {}
        name = data[:name].to_s.strip
        next unless name.match?(HackatimeLink::NAME_FORMAT) && name.length <= HackatimeLink::NAME_MAX

        { name: name, repo: RepoUrl.normalize(data[:repo_url]) }
      end.uniq { |candidate| candidate[:name] }
    end

    def repo_matches(candidate)
      return [] unless candidate[:repo]

      @projects.select { |project| project.repo_url.present? && RepoUrl.normalize(project.repo_url) == candidate[:repo] }
    end

    def repo_match(candidate)
      matches = repo_matches(candidate)
      matches.first if matches.one?
    end

    # Several projects on the same repo: not certain which one it is, so neither link nor guess by name.
    def repo_ambiguous?(candidate) = repo_matches(candidate).many?

    def link_by_repo(project, name)
      return if project.link_suggestions.exists?(hackatime_project: name, state: "declined")

      project.hackatime_links.create!(user_id: @user.id, hackatime_project: name, link_method: "auto_repo")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil # linked to another project in the meantime, or the project is full
    end

    # The single live project whose name is closest: exact (normalised) equality beats containment. A tie at the
    # best level is ambiguous, so nothing is suggested.
    def name_match(candidate)
      close = @projects.select { |project| self.class.close_names?(project.name, candidate[:name]) }
      exact = close.select { |project| self.class.name_key(project.name) == self.class.name_key(candidate[:name]) }
      best = exact.presence || close
      best.first if best.one?
    end
  end
end
