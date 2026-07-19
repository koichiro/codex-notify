# frozen_string_literal: true

module CodexNotify
  module DestinationName
    PATTERN = /\A[A-Z0-9_]+\z/

    class Error < StandardError; end

    module_function

    def normalize(value)
      normalized = value.to_s.strip.upcase
      return normalized if PATTERN.match?(normalized)

      raise Error, 'destination must contain only A-Z, 0-9, and _'
    end
  end
end
