# frozen_string_literal: true

require 'dotenv'
require 'etc'
require 'optparse'
require 'pathname'
require_relative 'security'

module CodexNotify
  module HookConfig
    DEFAULT_ENV_PATH = '.env'
    DEFAULT_STATE_PATH = Pathname(File.expand_path('~/.codex-notify-hook/state.json'))
    DEFAULT_MODE = 'normal'
    MODES = %w[normal debug].freeze
    APP_ROOT = Pathname(__dir__).join('../..').expand_path

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

      env_paths.each { |env_path| Security.warn_if_env_file_insecure(env_path, stderr:) }
      loader = override ? Dotenv.method(:overload) : Dotenv.method(:load)
      loader.call(*env_paths.map(&:to_s))
    end

    def system_user_name
      ENV['USER'] || ENV['USERNAME'] || Etc.getlogin || 'user'
    rescue StandardError
      ENV['USER'] || ENV['USERNAME'] || 'user'
    end

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
        opts.on('--env-file PATH') { |v| options.env_file = v }
        opts.on('--token TOKEN', 'Deprecated: use SLACK_BOT_TOKEN or --env-file') do |v|
          options.token = v
          options.token_from_cli = true
        end
        opts.on('--channel CHANNEL') { |v| options.channel = v }
        opts.on('--user-name NAME') { |v| options.user_name = v }
        opts.on('--title TITLE') { |v| options.title = v }
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
      load_env_file(options.env_file, stderr:)
      options.token ||= ENV['SLACK_BOT_TOKEN']
      options.channel ||= ENV['SLACK_CHANNEL']
      options.user_name ||= ENV['CODEX_NOTIFY_USER_NAME'] || system_user_name
      options.title ||= ENV['CODEX_NOTIFY_TITLE']
      options.event_name ||= ENV['CODEX_HOOK_EVENT'] || ENV['CODEX_NOTIFY_HOOK_EVENT']
      options.mode ||= ENV['CODEX_NOTIFY_MODE'] || DEFAULT_MODE
      raise OptionParser::InvalidArgument, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(options.mode)
      options
    end
  end
end
