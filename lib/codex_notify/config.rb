# frozen_string_literal: true

require 'dotenv'
require 'etc'
require 'optparse'
require 'pathname'

module CodexNotify
  module Config
    DEFAULT_ENV_PATH = '.env'
    DEFAULT_SESSIONS_DIR = Pathname(File.expand_path('~/.codex/sessions'))
    APP_ROOT = Pathname(__dir__).join('../..').expand_path

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
      keyword_init: true
    )

    module_function

    def app_root
      APP_ROOT
    end

    def resolve_env_path(path = DEFAULT_ENV_PATH)
      env_path = Pathname(path)
      return env_path if env_path.absolute?

      [Pathname(Dir.pwd).join(env_path), app_root.join(env_path)].find(&:exist?)
    end

    def load_env_file(path = DEFAULT_ENV_PATH, override: false)
      env_path = resolve_env_path(path)
      return unless env_path
      return unless env_path.exist?

      loader = override ? Dotenv.method(:overload) : Dotenv.method(:load)
      loader.call(env_path.to_s)
    end

    def system_user_name
      Etc.getlogin || ENV['USER'] || ENV['USERNAME'] || 'user'
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
        once: false
      )

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: codex-notify [options]'
        opts.on('--env-file PATH') { |v| options.env_file = v }
        opts.on('--token TOKEN') { |v| options.token = v }
        opts.on('--channel CHANNEL') { |v| options.channel = v }
        opts.on('--user-name NAME') { |v| options.user_name = v }
        opts.on('--prompt PROMPT') { |v| options.prompt = v }
        opts.on('--title TITLE') { |v| options.title = v }
        opts.on('--include-tools') { options.include_tools = true }
        opts.on('--throttle-sec FLOAT', Float) { |v| options.throttle_sec = v }
        opts.on('--sessions-dir PATH') { |v| options.sessions_dir = v }
        opts.on('--session-file PATH') { |v| options.session_file = v }
        opts.on('--poll-sec FLOAT', Float) { |v| options.poll_sec = v }
        opts.on('--once') { options.once = true }
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
      options
    end
  end
end
