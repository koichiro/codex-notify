# frozen_string_literal: true

module CodexNotify
  module Security
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

    def warn_if_env_file_insecure(path, stderr: $stderr)
      stat = File.stat(path)
      return unless stat.file?
      return if (stat.mode & 0o077).zero?

      permissions = format('%04o', stat.mode & 0o777)
      stderr.puts(
        "WARNING: env file #{path} has permissions #{permissions}; " \
        "use `chmod 600 #{path}` to restrict access to secrets."
      )
    rescue NotImplementedError, SystemCallError
      nil
    end

    def warn_deprecated_cli_token(stderr: $stderr)
      stderr.puts(
        'WARNING: --token is deprecated because command-line arguments may be visible in process lists ' \
        'and shell history; use SLACK_BOT_TOKEN or a permission-restricted env file.'
      )
    end

    def warn_deprecated_repository_credentials(path, keys, stderr: $stderr)
      stderr.puts(
        "WARNING: repository Slack settings #{keys.join(' and ')} loaded from automatically discovered env file #{path} " \
        'are deprecated; configure a trusted destination profile and use CODEX_NOTIFY_DESTINATION.'
      )
    end

    def warn_ignored_repository_credentials(path, keys, policy: nil, stderr: $stderr)
      reason = policy ? " under the #{policy} policy" : ''
      stderr.puts(
        "WARNING: ignored #{keys.join(', ')} from automatically discovered repository env file #{path}#{reason}."
      )
    end
  end
end
