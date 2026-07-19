# frozen_string_literal: true

require 'optparse'
require 'pathname'
require_relative 'config_support'
require_relative 'destination_resolver'
require_relative 'env_source_loader'

module CodexNotify
  module Config
    extend ConfigSupport

    DEFAULT_ENV_PATH = ConfigSupport::DEFAULT_ENV_PATH
    DEFAULT_SESSIONS_DIR = Pathname(File.expand_path('~/.codex/sessions'))
    DEFAULT_OUTBOX_DIR = Pathname(File.expand_path('~/.codex-notify/outbox'))

    class Error < StandardError; end

    Args = Struct.new(
      :env_file,
      :env_file_explicit,
      :config_file,
      :token,
      :channel,
      :destination,
      :user_name,
      :prompt,
      :title,
      :include_tools,
      :throttle_sec,
      :sessions_dir,
      :session_file,
      :poll_sec,
      :once,
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
        prompt: nil,
        title: nil,
        include_tools: false,
        throttle_sec: 1.05,
        sessions_dir: DEFAULT_SESSIONS_DIR.to_s,
        session_file: nil,
        poll_sec: 1.0,
        once: false,
        outbox_dir: nil,
        outbox_action: nil,
        outbox_id: nil,
        token_from_cli: false
      )

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: codex-notify [options]'
        add_common_options(opts, options)
        opts.on('--prompt PROMPT') { |v| options.prompt = v }
        opts.on('--include-tools') { options.include_tools = true }
        opts.on('--throttle-sec FLOAT', Float) { |v| options.throttle_sec = v }
        opts.on('--sessions-dir PATH') { |v| options.sessions_dir = v }
        opts.on('--session-file PATH') { |v| options.session_file = v }
        opts.on('--poll-sec FLOAT', Float) { |v| options.poll_sec = v }
        opts.on('--once') { options.once = true }
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

      eligible = eligible_sources(sources, policy:)
      trusted = trusted_sources(sources)
      options.user_name ||= eligible.lookup('CODEX_NOTIFY_USER_NAME')&.value || system_user_name
      options.title ||= eligible.lookup('CODEX_NOTIFY_TITLE')&.value
      options.prompt ||= eligible.lookup('CODEX_PROMPT')&.value
      options.outbox_dir ||= trusted.lookup('CODEX_NOTIFY_OUTBOX_DIR')&.value || DEFAULT_OUTBOX_DIR.to_s
      options
    rescue ConfigSupport::Error, EnvSourceLoader::Error, TrustedConfigLoader::Error, DestinationResolver::Error => e
      raise Error, e.message
    end
  end
end
