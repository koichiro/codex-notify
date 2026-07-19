# frozen_string_literal: true

require 'optparse'
require 'pathname'
require_relative 'config_support'

module CodexNotify
  module Config
    extend ConfigSupport

    DEFAULT_ENV_PATH = ConfigSupport::DEFAULT_ENV_PATH
    DEFAULT_SESSIONS_DIR = Pathname(File.expand_path('~/.codex/sessions'))
    DEFAULT_OUTBOX_DIR = Pathname(File.expand_path('~/.codex-notify/outbox'))

    Args = Struct.new(
      :env_file,
      :token,
      :channel,
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
        token: nil,
        channel: nil,
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
      apply_common_config(options, stderr:)
      options.outbox_dir ||= ENV['CODEX_NOTIFY_OUTBOX_DIR'] || DEFAULT_OUTBOX_DIR.to_s
      options.prompt ||= ENV['CODEX_PROMPT']
      options
    end
  end
end
