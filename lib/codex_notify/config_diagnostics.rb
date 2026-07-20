# frozen_string_literal: true

module CodexNotify
  module ConfigDiagnostics
    module_function

    def warn_if_file_insecure(path, label:, stderr:)
      stat = File.stat(path)
      return unless stat.file?
      return if (stat.mode & 0o077).zero?

      permissions = format('%04o', stat.mode & 0o777)
      stderr.puts(
        "WARNING: #{label} #{path} has permissions #{permissions}; " \
        "use `chmod 600 #{path}` to restrict access to secrets."
      )
    rescue NotImplementedError, SystemCallError
      nil
    end

    def warn_if_env_file_insecure(path, stderr:)
      warn_if_file_insecure(path, label: 'env file', stderr:)
    end

    def warn_deprecated_cli_token(stderr:)
      stderr.puts(
        'WARNING: --token is deprecated because command-line arguments may be visible in process lists ' \
        'and shell history; use SLACK_BOT_TOKEN or a permission-restricted env file.'
      )
    end

    def warn_deprecated_repository_credentials(path, keys, stderr:)
      stderr.puts(
        "WARNING: insecure legacy mode loaded repository Slack settings #{keys.join(' and ')} from automatically " \
        "discovered env file #{path}; this temporary compatibility mode will be removed in a future major release. " \
        'Configure a trusted destination profile and use CODEX_NOTIFY_DESTINATION.'
      )
    end

    def warn_ignored_repository_policy(path, stderr:)
      stderr.puts(
        "WARNING: ignored CODEX_NOTIFY_ENV_POLICY from automatically discovered repository env file #{path}; " \
        'the policy must come from trusted configuration.'
      )
    end

    def warn_ignored_repository_credentials(path, keys, policy: nil, stderr:)
      reason = policy ? " under the #{policy} policy" : ''
      stderr.puts(
        "WARNING: ignored #{keys.join(', ')} from automatically discovered repository env file #{path}#{reason}."
      )
    end

    def warn_deprecated_tool_config(path, keys, stderr:)
      stderr.puts(
        "WARNING: #{keys.join(', ')} loaded from legacy codex-notify env file #{path}; " \
        'move trusted settings to the XDG config file.'
      )
    end
  end
end
