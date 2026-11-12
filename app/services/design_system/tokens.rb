# Reads the design tokens straight from app/assets/stylesheets/tokens.css, so the development style guide and the
# contrast tests always describe what the stylesheet really says (there is no second copy of any value).
module DesignSystem
  class Tokens
    PATH = Rails.root.join("app/assets/stylesheets/tokens.css")
    DECLARATION = /^\s*(--[a-z0-9-]+)\s*:\s*([^;]+);(?:\s*\/\*\s*(.*?)\s*\*\/)?/
    HEX = /\A#\h{6}\z/

    Token = Struct.new(:name, :value, :comment, keyword_init: true)

    # Every custom property in tokens.css, in file order.
    def self.all
      @all ||= PATH.read.scan(DECLARATION).map { |name, value, comment| Token.new(name: name, value: value.strip, comment: comment.to_s) }.freeze
    end

    def self.find(name) = all.find { |token| token.name == name }

    # The final value of a token with var(--other) references followed ("#a60040" for --color-link).
    def self.resolve(name, depth = 0)
      raise ArgumentError, "token loop at #{name}" if depth > 8

      value = find(name)&.value or raise ArgumentError, "unknown token #{name}"
      reference = value.match(/\Avar\((--[a-z0-9-]+)\)\z/)
      reference ? resolve(reference[1], depth + 1) : value
    end

    def self.colors
      all.select { |token| token.name.start_with?("--color-") }.map do |token|
        Token.new(name: token.name, value: resolve(token.name), comment: token.comment)
      end
    end

    def self.hex?(value) = value.match?(HEX)
  end
end
