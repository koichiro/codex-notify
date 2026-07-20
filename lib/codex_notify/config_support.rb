# frozen_string_literal: true

require 'dotenv'
require 'etc'
require 'pathname'
require_relative 'config_diagnostics'

module CodexNotify
  module ConfigSupport
    class Error < StandardError; end

    DEFAULT_ENV_PATH = '.env'
    DEFAULT_ENV_POLICY = 'restricted'
    ENV_POLICIES = %w[legacy restricted].freeze
    REPOSITORY_ALLOWED_KEYS = %w[
      CODEX_NOTIFY_DESTINATION
      CODEX_NOTIFY_TITLE
      CODEX_NOTIFY_USER_NAME
      CODEX_NOTIFY_MODE
    ].freeze
    REPOSITORY_CREDENTIAL_PATTERN = /\ASLACK_(?:BOT_TOKEN|CHANNEL)(?:__.*)?\z/
    APP_ROOT = Pathname(__dir__).join('../..').expand_path

    def app_root
      APP_ROOT
    end

    def resolve_env_paths(path = DEFAULT_ENV_PATH)
      env_path = Pathname(path)
      return [env_path] if env_path.absolute?

      [Pathname(Dir.pwd).join(env_path), app_root.join(env_path)].select(&:exist?).uniq
    end

    def load_env_file(path = DEFAULT_ENV_PATH, override: false, stderr: $stderr)
      env_paths = resolve_env_paths(path)
      return if env_paths.empty?

      env_paths.each { |env_path| ConfigDiagnostics.warn_if_env_file_insecure(env_path, stderr:) }
      loader = override ? Dotenv.method(:overload) : Dotenv.method(:load)
      loader.call(*env_paths.map(&:to_s))
    end

    def system_user_name
      ENV['USER'] || ENV['USERNAME'] || Etc.getlogin || 'user'
    rescue StandardError
      ENV['USER'] || ENV['USERNAME'] || 'user'
    end

    def getenv_any(keys)
      keys.each do |key|
        value = ENV[key]
        return value if value && !value.empty?
      end
      nil
    end

    def add_common_options(parser, options)
      parser.on('--config PATH') do |value|
        options.config_file = value
      end
      parser.on('--migrate-config', 'Create trusted YAML from a legacy env file') do
        options.migrate_config = true
      end
      parser.on('--env-file PATH') do |value|
        options.env_file = value
        options.env_file_explicit = true if options.respond_to?(:env_file_explicit=)
      end
      parser.on('--token TOKEN', 'Deprecated: use the XDG config file or SLACK_BOT_TOKEN') do |value|
        options.token = value
        options.token_from_cli = true
      end
      parser.on('--channel CHANNEL') { |value| options.channel = value }
      parser.on('--destination NAME') { |value| options.destination = value } if options.respond_to?(:destination=)
      parser.on('--user-name NAME') { |value| options.user_name = value }
      parser.on('--title TITLE') { |value| options.title = value }
      if options.respond_to?(:outbox_action=)
        parser.on('--outbox-status') { options.outbox_action = :status }
        parser.on('--drain-outbox') { options.outbox_action = :drain }
        parser.on('--retry-outbox ID') do |value|
          options.outbox_action = :retry
          options.outbox_id = value
        end
      end
    end

    def resolve_policy(sources, stderr: $stderr)
      result = trusted_sources(sources).lookup('CODEX_NOTIFY_ENV_POLICY')
      policy = result ? result.value.strip.downcase : DEFAULT_ENV_POLICY
      raise Error, "environment policy must be one of: #{ENV_POLICIES.join(', ')}" unless ENV_POLICIES.include?(policy)

      warn_if_legacy_tool_source(result&.source, ['CODEX_NOTIFY_ENV_POLICY'], stderr:)
      policy
    end

    def apply_destination(options, sources, policy:, stderr: $stderr)
      eligible = eligible_sources(sources, policy:)
      resolution = DestinationResolver.new(
        selection_sources: sources,
        profile_sources: trusted_sources(sources),
        default_sources: eligible
      ).resolve(destination: options.destination, token: options.token, channel: options.channel)

      options.destination = resolution.destination
      options.token = resolution.token
      options.channel = resolution.channel

      used_sources = [resolution.token_source, resolution.channel_source].compact
      source_keys = [
        [resolution.token_source, 'SLACK_BOT_TOKEN'],
        [resolution.channel_source, 'SLACK_CHANNEL']
      ]
      repository_keys = source_keys.filter_map { |source, key| key if source&.kind == :repository }
      if repository_keys.any?
        source = used_sources.find { |candidate| candidate.kind == :repository }
        ConfigDiagnostics.warn_deprecated_repository_credentials(source.path, repository_keys, stderr:)
      end

      tool_keys = [
        [resolution.token_source, resolution.destination ? "destination #{resolution.destination} token" : 'SLACK_BOT_TOKEN'],
        [resolution.channel_source, resolution.destination ? "destination #{resolution.destination} channel" : 'SLACK_CHANNEL']
      ].filter_map { |source, key| key if source&.kind == :tool }
      warn_if_legacy_tool_source(used_sources.find { |source| source.kind == :tool }, tool_keys, stderr:)
    end

    def eligible_sources(sources, policy:)
      return sources unless policy == 'restricted'

      sources.restrict_kind(:repository, keys: REPOSITORY_ALLOWED_KEYS)
    end

    def trusted_sources(sources)
      sources.excluding_kind(:repository)
    end

    def warn_ignored_repository_values(sources, policy:, stderr:)
      sources.select { |source| source.kind == :repository }.each do |source|
        policy_value = source.values['CODEX_NOTIFY_ENV_POLICY']
        if policy_value && !policy_value.empty?
          ConfigDiagnostics.warn_ignored_repository_policy(source.path, stderr:)
        end

        ignored = source.values.keys.grep(REPOSITORY_CREDENTIAL_PATTERN)
        ignored.select! { |key| key.include?('__') } if policy == 'legacy'
        next if ignored.empty?

        reason = policy == 'restricted' ? policy : nil
        ConfigDiagnostics.warn_ignored_repository_credentials(source.path, ignored.sort, policy: reason, stderr:)
      end
    end

    def warn_if_legacy_tool_source(source, keys, stderr:)
      return unless source&.kind == :tool && keys.any?

      ConfigDiagnostics.warn_deprecated_tool_config(source.path, keys, stderr:)
    end

  end
end
