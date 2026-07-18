# frozen_string_literal: true

require 'optparse'
require 'pathname'
require_relative 'config_support'

module CodexNotify
  module HookConfig
    extend ConfigSupport

    DEFAULT_ENV_PATH = ConfigSupport::DEFAULT_ENV_PATH
    DEFAULT_STATE_PATH = Pathname(File.expand_path('~/.codex-notify-hook/state.json'))
    DEFAULT_MODE = 'normal'
    MODES = %w[normal debug].freeze
    ENV_POLICIES = %w[legacy restricted].freeze
    DESTINATION_PATTERN = /\A[A-Z0-9_]+\z/
    REPOSITORY_ALLOWED_KEYS = %w[
      CODEX_NOTIFY_DESTINATION
      CODEX_NOTIFY_TITLE
      CODEX_NOTIFY_USER_NAME
      CODEX_NOTIFY_MODE
    ].freeze
    REPOSITORY_CREDENTIAL_PATTERN = /\ASLACK_(?:BOT_TOKEN|CHANNEL)(?:__.*)?\z/

    class Error < StandardError; end

    EnvSource = Struct.new(:kind, :path, :values, keyword_init: true)

    Args = Struct.new(
      :env_file,
      :env_file_explicit,
      :token,
      :channel,
      :destination,
      :user_name,
      :title,
      :state_file,
      :event_name,
      :mode,
      :token_from_cli,
      keyword_init: true
    )

    module_function

    def build_parser
      options = Args.new(
        env_file: DEFAULT_ENV_PATH,
        env_file_explicit: false,
        token: nil,
        channel: nil,
        destination: nil,
        user_name: nil,
        title: nil,
        state_file: DEFAULT_STATE_PATH.to_s,
        event_name: nil,
        mode: nil,
        token_from_cli: false
      )

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: codex-notify-hook [options]'
        add_common_options(opts, options)
        opts.on('--destination NAME') { |v| options.destination = v }
        opts.on('--state-file PATH') { |v| options.state_file = v }
        opts.on('--event NAME') { |v| options.event_name = v }
        opts.on('--mode MODE', MODES) { |v| options.mode = v }
      end

      [parser, options]
    end

    def parse_args(argv = nil, stderr: $stderr)
      parser, options = build_parser
      parser.parse!(argv || [])
      Security.warn_deprecated_cli_token(stderr:) if options.token_from_cli

      sources = env_sources(options, stderr:)
      policy = resolve_policy(sources)
      warn_ignored_repository_values(sources, policy:, stderr:)
      apply_destination(options, sources, policy:, stderr:)
      apply_presentation(options, sources, policy:)

      raise Error, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(options.mode)
      options
    end

    def env_sources(options, stderr:)
      process = EnvSource.new(kind: :process, path: nil, values: ENV.to_h)
      paths = resolve_env_paths(options.env_file)
      file_sources = paths.map do |path|
        Security.warn_if_env_file_insecure(path, stderr:)
        kind = source_kind(path, explicit: options.env_file_explicit)
        EnvSource.new(kind:, path: path.expand_path, values: Dotenv.parse(path.to_s))
      rescue SystemCallError => e
        raise Error, "could not read env file #{path}: #{e.class}"
      end
      [process, *file_sources]
    end

    def source_kind(path, explicit:)
      return :explicit if explicit

      tool_env_path = app_root.join(DEFAULT_ENV_PATH).expand_path
      path.expand_path == tool_env_path ? :tool : :repository
    end

    def resolve_policy(sources)
      raw = lookup(trusted_sources(sources), 'CODEX_NOTIFY_ENV_POLICY')&.first
      policy = raw ? raw.strip.downcase : 'legacy'
      return policy if ENV_POLICIES.include?(policy)

      raise Error, "environment policy must be one of: #{ENV_POLICIES.join(', ')}"
    end

    def apply_destination(options, sources, policy:, stderr:)
      repository_sources = sources.select { |source| source.kind == :repository }
      selected = options.destination || lookup(sources, 'CODEX_NOTIFY_DESTINATION')&.first

      if selected
        destination = normalize_destination(selected)
        apply_profile(options, destination, trusted_sources(sources))
        options.destination = destination
        return
      end

      apply_default_destination(options, sources, policy:, repository_sources:, stderr:)
    end

    def normalize_destination(value)
      normalized = value.to_s.strip.upcase
      return normalized if DESTINATION_PATTERN.match?(normalized)

      raise Error, 'destination must contain only A-Z, 0-9, and _'
    end

    def apply_profile(options, destination, sources)
      token_key = "SLACK_BOT_TOKEN__#{destination}"
      channel_key = "SLACK_CHANNEL__#{destination}"
      channel = lookup(sources, channel_key)&.first
      raise Error, "destination #{destination} is not configured: missing #{channel_key}" unless channel

      token = options.token || lookup(sources, token_key)&.first || lookup(sources, 'SLACK_BOT_TOKEN')&.first
      raise Error, "destination #{destination} has no Slack bot token" unless token

      options.token = token
      options.channel ||= channel
    end

    def apply_default_destination(options, sources, policy:, repository_sources:, stderr:)
      eligible = eligible_sources(sources, policy:)
      token_result = lookup(eligible, 'SLACK_BOT_TOKEN') unless options.token
      channel_result = lookup(eligible, 'SLACK_CHANNEL') unless options.channel
      options.token ||= token_result&.first
      options.channel ||= channel_result&.first

      used = { 'SLACK_BOT_TOKEN' => token_result, 'SLACK_CHANNEL' => channel_result }.filter_map do |key, result|
        key if result&.last&.kind == :repository
      end
      return if used.empty? || repository_sources.empty?

      Security.warn_deprecated_repository_credentials(repository_sources.first.path, used, stderr:)
    end

    def apply_presentation(options, sources, policy:)
      eligible = eligible_sources(sources, policy:)
      options.user_name ||= lookup(eligible, 'CODEX_NOTIFY_USER_NAME')&.first || system_user_name
      options.title ||= lookup(eligible, 'CODEX_NOTIFY_TITLE')&.first
      options.event_name ||= lookup(eligible, 'CODEX_HOOK_EVENT')&.first ||
                            lookup(eligible, 'CODEX_NOTIFY_HOOK_EVENT')&.first
      options.mode ||= lookup(eligible, 'CODEX_NOTIFY_MODE')&.first || DEFAULT_MODE
    end

    def eligible_sources(sources, policy:)
      return sources unless policy == 'restricted'

      sources.map do |source|
        next source unless source.kind == :repository

        allowed = source.values.slice(*REPOSITORY_ALLOWED_KEYS)
        EnvSource.new(kind: source.kind, path: source.path, values: allowed)
      end
    end

    def trusted_sources(sources)
      sources.reject { |source| source.kind == :repository }
    end

    def warn_ignored_repository_values(sources, policy:, stderr:)
      sources.select { |source| source.kind == :repository }.each do |source|
        ignored = source.values.keys.grep(REPOSITORY_CREDENTIAL_PATTERN)
        ignored.select! { |key| key.include?('__') } if policy == 'legacy'
        next if ignored.empty?

        reason = policy == 'restricted' ? policy : nil
        Security.warn_ignored_repository_credentials(source.path, ignored.sort, policy: reason, stderr:)
      end
    end

    def lookup(sources, key)
      sources.each do |source|
        value = source.values[key]
        return [value, source] if value && !value.empty?
      end
      nil
    end
  end
end
