# frozen_string_literal: true

module CodexNotify
  module ConfigDiagnostics
    module_function

    def warn_if_env_file_insecure(path, stderr:)
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

    def warn_deprecated_cli_token(stderr:)
      stderr.puts(
        'WARNING: --token is deprecated because command-line arguments may be visible in process lists ' \
        'and shell history; use SLACK_BOT_TOKEN or a permission-restricted env file.'
      )
    end

    def warn_deprecated_repository_credentials(path, keys, stderr:)
      stderr.puts(
        "WARNING: repository Slack settings #{keys.join(' and ')} loaded from automatically discovered env file #{path} " \
        'are deprecated; configure a trusted destination profile and use CODEX_NOTIFY_DESTINATION.'
      )
    end

    def warn_ignored_repository_credentials(path, keys, policy: nil, stderr:)
      reason = policy ? " under the #{policy} policy" : ''
      stderr.puts(
        "WARNING: ignored #{keys.join(', ')} from automatically discovered repository env file #{path}#{reason}."
      )
    end
  end
end
