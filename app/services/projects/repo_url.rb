module Projects
  # GitHub repository URLs in one canonical form, so two spellings of the same repo compare equal:
  # lowercase, https, no "www.", no ".git", no trailing slash. Only the plain https://github.com/<owner>/<repo>
  # shape is accepted; anything else (other hosts, deep links like /tree/main, query strings, ssh remotes) is nil.
  module RepoUrl
    PATTERN = %r{\A(?:https?://)(?:www\.)?github\.com/(?<owner>[a-z0-9-]{1,39})/(?<repo>[a-z0-9._-]{1,100}?)(?:\.git)?/*\z}
    MAX_LENGTH = 300

    # "HTTP://www.GitHub.com/Octo/Cat.git/" -> "https://github.com/octo/cat"; nil when it is not a GitHub repo URL.
    def self.normalize(value)
      text = value.to_s.strip.downcase
      return if text.empty? || text.length > MAX_LENGTH

      match = PATTERN.match(text)
      return unless match && !match[:repo].match?(/\A\.+\z/)

      "https://github.com/#{match[:owner]}/#{match[:repo]}"
    end

    # True only when both are GitHub repo URLs that normalise to the same repo.
    def self.same?(first, second)
      normalized = normalize(first)
      normalized.present? && normalized == normalize(second)
    end
  end
end
