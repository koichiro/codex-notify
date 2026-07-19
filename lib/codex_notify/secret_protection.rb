# frozen_string_literal: true

module CodexNotify
  module SecretProtection
    REDACTED = '[REDACTED]'
    SENSITIVE_NAME = /(?:authorization|proxy[-_]?authorization|token|secret|password|passwd|api[-_]?key)/i
    KNOWN_SECRET_PATTERNS = [
      /\bxox[baprs]-[A-Za-z0-9][A-Za-z0-9-]*\b/,
      /\bxapp-[A-Za-z0-9][A-Za-z0-9-]*\b/,
      /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
      /\bsk-[A-Za-z0-9_-]{16,}\b/,
      /\bAKIA[0-9A-Z]{16}\b/
    ].freeze

    module_function

    def redact(value)
      text = value.to_s.dup

      text.gsub!(/(\b(?:[A-Za-z_][A-Za-z0-9_.-]*)?(?:proxy[-_]?authorization|authorization)[A-Za-z0-9_.-]*\s*[=:]\s*)(?:(?:Bearer|Basic)\s+)?[^\s'",;}]+/i) do
        "#{Regexp.last_match(1)}#{REDACTED}"
      end
      text.gsub!(/(--(?:token|password|passwd|secret|api[-_]?key)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s]+)/i) do
        "#{Regexp.last_match(1)}#{REDACTED}"
      end
      text.gsub!(/("[^"]*#{SENSITIVE_NAME.source}[^"]*"\s*:\s*)(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s,}\]]+)/i) do
        "#{Regexp.last_match(1)}#{REDACTED}"
      end
      text.gsub!(/(\b(?:[A-Za-z_][A-Za-z0-9_.-]*)?#{SENSITIVE_NAME.source}[A-Za-z0-9_.-]*\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/i) do
        "#{Regexp.last_match(1)}#{REDACTED}"
      end
      KNOWN_SECRET_PATTERNS.each { |pattern| text.gsub!(pattern, REDACTED) }

      text
    end
  end
end
