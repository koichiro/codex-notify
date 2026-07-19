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
    class Error < StandardError; end

    Args = Struct.new(
      :env_file,
      :env_file_explicit,
      :config_file,
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
        config_file: nil,
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
        explicit: options.env_file_explicit,
        config_path: options.config_file
      )
      policy = resolve_policy(sources, stderr:)
      warn_ignored_repository_values(sources, policy:, stderr:)
      apply_destination(options, sources, policy:, stderr:)
      apply_presentation(options, sources, policy:)
      options.outbox_dir ||= "#{options.state_file}.outbox"

      raise Error, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(options.mode)
      options
    rescue ConfigSupport::Error, EnvSourceLoader::Error, TrustedConfigLoader::Error, DestinationResolver::Error => e
      raise Error, e.message
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

  end
end
