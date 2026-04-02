# frozen_string_literal: true

require 'dotenv'
require 'etc'
require 'optparse'
require 'pathname'

module CodexNotify
  module HookConfig
    DEFAULT_ENV_PATH = '.env'
    DEFAULT_STATE_PATH = Pathname(File.expand_path('~/.codex-notify-hook/state.json'))

    Args = Struct.new(
      :env_file,
      :token,
      :channel,
      :user_name,
      :title,
      :state_file,
      :event_name,
      keyword_init: true
    )

    module_function

    def load_env_file(path = DEFAULT_ENV_PATH, override: false)
      env_path = Pathname(path)
      return unless env_path.exist?

      loader = override ? Dotenv.method(:overload) : Dotenv.method(:load)
      loader.call(env_path.to_s)
    end

    def system_user_name
      Etc.getlogin || ENV['USER'] || ENV['USERNAME'] || 'user'
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
        event_name: nil
      )

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: codex-notify-hook [options]'
        opts.on('--env-file PATH') { |v| options.env_file = v }
        opts.on('--token TOKEN') { |v| options.token = v }
        opts.on('--channel CHANNEL') { |v| options.channel = v }
        opts.on('--user-name NAME') { |v| options.user_name = v }
        opts.on('--title TITLE') { |v| options.title = v }
        opts.on('--state-file PATH') { |v| options.state_file = v }
        opts.on('--event NAME') { |v| options.event_name = v }
      end

      [parser, options]
    end

    def parse_args(argv = nil)
      parser, options = build_parser
      parser.parse!(argv || [])
      load_env_file(options.env_file)
      options.token ||= ENV['SLACK_BOT_TOKEN']
      options.channel ||= ENV['SLACK_CHANNEL']
      options.user_name ||= ENV['CODEX_NOTIFY_USER_NAME'] || system_user_name
      options.title ||= ENV['CODEX_NOTIFY_TITLE']
      options.event_name ||= ENV['CODEX_HOOK_EVENT'] || ENV['CODEX_NOTIFY_HOOK_EVENT']
      options
    end
  end
end
