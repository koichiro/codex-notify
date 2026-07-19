# frozen_string_literal: true

require 'optparse'
require 'pathname'
require_relative 'config_support'
require_relative 'destination_resolver'
require_relative 'env_source_loader'

module CodexNotify
  module HookConfig
    extend ConfigSupport

    DEFAULT_ENV_PATH = ConfigSupport::DEFAULT_ENV_PATH
    DEFAULT_STATE_PATH = Pathname(File.expand_path('~/.codex-notify-hook/state.json'))
    DEFAULT_MODE = 'normal'
    MODES = %w[normal debug].freeze
    ENV_POLICIES = %w[legacy restricted].freeze
    REPOSITORY_ALLOWED_KEYS = %w[
      CODEX_NOTIFY_DESTINATION
      CODEX_NOTIFY_TITLE
      CODEX_NOTIFY_USER_NAME
      CODEX_NOTIFY_MODE
    ].freeze
    REPOSITORY_CREDENTIAL_PATTERN = /\ASLACK_(?:BOT_TOKEN|CHANNEL)(?:__.*)?\z/

    class Error < StandardError; end

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
      :outbox_dir,
      :outbox_action,
      :outbox_id,
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
        outbox_dir: nil,
        outbox_action: nil,
        outbox_id: nil,
        token_from_cli: false
      )

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: codex-notify-hook [options]'
        add_common_options(opts, options)
        opts.on('--destination NAME') { |v| options.destination = v }
        opts.on('--state-file PATH') { |v| options.state_file = v }
        opts.on('--event NAME') { |v| options.event_name = v }
        opts.on('--mode MODE', MODES) { |v| options.mode = v }
        opts.on('--outbox-dir PATH') { |v| options.outbox_dir = v }
      end

      [parser, options]
    end

    def parse_args(argv = nil, stderr: $stderr)
      parser, options = build_parser
      parser.parse!(argv || [])
      ConfigDiagnostics.warn_deprecated_cli_token(stderr:) if options.token_from_cli

      sources = EnvSourceLoader.new(app_root:, stderr:).load(
        path: options.env_file,
        explicit: options.env_file_explicit
      )
      policy = resolve_policy(sources)
      warn_ignored_repository_values(sources, policy:, stderr:)
      apply_destination(options, sources, policy:, stderr:)
      apply_presentation(options, sources, policy:)
      options.outbox_dir ||= "#{options.state_file}.outbox"

      raise Error, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(options.mode)
      options
    rescue EnvSourceLoader::Error, DestinationResolver::Error => e
      raise Error, e.message
    end

    def resolve_policy(sources)
      raw = trusted_sources(sources).lookup('CODEX_NOTIFY_ENV_POLICY')&.value
      policy = raw ? raw.strip.downcase : 'legacy'
      return policy if ENV_POLICIES.include?(policy)

      raise Error, "environment policy must be one of: #{ENV_POLICIES.join(', ')}"
    end

    def apply_destination(options, sources, policy:, stderr:)
      eligible = eligible_sources(sources, policy:)
      resolution = DestinationResolver.new(
        selection_sources: sources,
        profile_sources: trusted_sources(sources),
        default_sources: eligible
      ).resolve(destination: options.destination, token: options.token, channel: options.channel)

      options.destination = resolution.destination
      options.token = resolution.token
      options.channel = resolution.channel

      used = {
        'SLACK_BOT_TOKEN' => resolution.token_source,
        'SLACK_CHANNEL' => resolution.channel_source
      }.filter_map { |key, source| key if source&.kind == :repository }
      return if used.empty?

      source = [resolution.token_source, resolution.channel_source].find { |candidate| candidate&.kind == :repository }
      ConfigDiagnostics.warn_deprecated_repository_credentials(source.path, used, stderr:)
    end

    def apply_presentation(options, sources, policy:)
      eligible = eligible_sources(sources, policy:)
      trusted = trusted_sources(sources)
      options.user_name ||= eligible.lookup('CODEX_NOTIFY_USER_NAME')&.value || system_user_name
      options.title ||= eligible.lookup('CODEX_NOTIFY_TITLE')&.value
      options.event_name ||= eligible.lookup('CODEX_HOOK_EVENT')&.value ||
                            eligible.lookup('CODEX_NOTIFY_HOOK_EVENT')&.value
      options.mode ||= eligible.lookup('CODEX_NOTIFY_MODE')&.value || DEFAULT_MODE
      options.outbox_dir ||= trusted.lookup('CODEX_NOTIFY_OUTBOX_DIR')&.value
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
        ignored = source.values.keys.grep(REPOSITORY_CREDENTIAL_PATTERN)
        ignored.select! { |key| key.include?('__') } if policy == 'legacy'
        next if ignored.empty?

        reason = policy == 'restricted' ? policy : nil
        ConfigDiagnostics.warn_ignored_repository_credentials(source.path, ignored.sort, policy: reason, stderr:)
      end
    end

  end
end
