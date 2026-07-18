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

    Args = Struct.new(
      :env_file,
      :token,
      :channel,
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
        token: nil,
        channel: nil,
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
        opts.on('--state-file PATH') { |v| options.state_file = v }
        opts.on('--event NAME') { |v| options.event_name = v }
        opts.on('--mode MODE', MODES) { |v| options.mode = v }
      end

      [parser, options]
    end

    def parse_args(argv = nil, stderr: $stderr)
      parser, options = build_parser
      parser.parse!(argv || [])
      apply_common_config(options, stderr:)
      options.event_name ||= ENV['CODEX_HOOK_EVENT'] || ENV['CODEX_NOTIFY_HOOK_EVENT']
      options.mode ||= ENV['CODEX_NOTIFY_MODE'] || DEFAULT_MODE
      raise OptionParser::InvalidArgument, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(options.mode)
      options
    end
  end
end
