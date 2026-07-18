# frozen_string_literal: true

require 'dotenv'
require 'etc'
require 'pathname'
require_relative 'security'

module CodexNotify
  module ConfigSupport
    DEFAULT_ENV_PATH = '.env'
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

      env_paths.each { |env_path| Security.warn_if_env_file_insecure(env_path, stderr:) }
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
      parser.on('--env-file PATH') { |value| options.env_file = value }
      parser.on('--token TOKEN', 'Deprecated: use SLACK_BOT_TOKEN or --env-file') do |value|
        options.token = value
        options.token_from_cli = true
      end
      parser.on('--channel CHANNEL') { |value| options.channel = value }
      parser.on('--user-name NAME') { |value| options.user_name = value }
      parser.on('--title TITLE') { |value| options.title = value }
    end

    def apply_common_config(options, stderr: $stderr)
      Security.warn_deprecated_cli_token(stderr:) if options.token_from_cli
      load_env_file(options.env_file, stderr:)
      options.token ||= ENV['SLACK_BOT_TOKEN']
      options.channel ||= ENV['SLACK_CHANNEL']
      options.user_name ||= ENV['CODEX_NOTIFY_USER_NAME'] || system_user_name
      options.title ||= ENV['CODEX_NOTIFY_TITLE']
      options
    end
  end
end
