#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'optparse'
require 'pathname'
require 'etc'
require 'time'
require 'uri'
require_relative 'log_event_parser'
require_relative 'message_formatter'
require_relative 'session_log'
require_relative 'stream_processor'

module CodexNotify
  module CLI
    SLACK_API = 'https://slack.com/api/chat.postMessage'
    DEFAULT_ENV_PATH = '.env'
    DEFAULT_SESSIONS_DIR = Pathname(File.expand_path('~/.codex/sessions'))

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

    def chunk_text(*args, **kwargs, &block)
      CodexNotify::MessageFormatter.chunk_text(*args, **kwargs, &block)
    end

    def fmt_block(*args, **kwargs)
      CodexNotify::MessageFormatter.fmt_block(*args, **kwargs)
    end

    def build_root_text(*args, **kwargs)
      CodexNotify::MessageFormatter.build_root_text(*args, **kwargs)
    end

    def fmt_plain(*args, **kwargs)
      CodexNotify::MessageFormatter.fmt_plain(*args, **kwargs)
    end

    def as_text(*args, **kwargs)
      CodexNotify::LogEventParser.as_text(*args, **kwargs)
    end

    def pretty_json(*args, **kwargs)
      CodexNotify::LogEventParser.pretty_json(*args, **kwargs)
    end

    def format_tool_payload(*args, **kwargs)
      CodexNotify::LogEventParser.format_tool_payload(*args, **kwargs)
    end

    def tool_event_type?(*args, **kwargs)
      CodexNotify::LogEventParser.tool_event_type?(*args, **kwargs)
    end

    def extract_events(*args, **kwargs)
      CodexNotify::LogEventParser.extract_events(*args, **kwargs)
    end

    def extract_session_id(*args, **kwargs)
      CodexNotify::LogEventParser.extract_session_id(*args, **kwargs)
    end

    def iter_follow_lines(*args, **kwargs, &block)
      CodexNotify::SessionLog.iter_follow_lines(*args, **kwargs, &block)
    end

    def find_latest_session_file(*args, **kwargs)
      CodexNotify::SessionLog.find_latest_session_file(*args, **kwargs)
    end

    def session_id_from_path(*args, **kwargs)
      CodexNotify::SessionLog.session_id_from_path(*args, **kwargs)
    end

    def process_events(*args, **kwargs)
      kwargs[:post_func] ||= method(:slack_post)
      CodexNotify::StreamProcessor.process_events(*args, **kwargs)
    end

    def process_codex_log_stream(*args, **kwargs)
      kwargs[:post_func] ||= method(:slack_post)
      CodexNotify::StreamProcessor.process_codex_log_stream(*args, **kwargs)
    end

    def load_env_file(path = DEFAULT_ENV_PATH, override: false)
      env_path = Pathname(path)
      return unless env_path.exist?

      env_path.read.each_line do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.start_with?('#') || !line.include?('=')

        key, value = line.split('=', 2)
        key = key.strip
        value = value.strip.gsub(/\A['"]|['"]\z/, '')
        next if !override && ENV[key] && !ENV[key].empty?

        ENV[key] = value
      end
    end

    def slack_post(token, channel, text, thread_ts = nil)
      payload = { channel:, text: }
      payload[:thread_ts] = thread_ts.to_s if thread_ts

      uri = URI(SLACK_API)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{token}"
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 20) do |http|
        http.request(request)
      end
      parsed = JSON.parse(response.body)
      raise "Slack API error: #{parsed}" unless parsed['ok']

      parsed
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

    def main(argv = nil, stdin: nil, stderr: $stderr)
      args = parse_args(argv)
      unless args.token && args.channel
        stderr.puts('ERROR: need --token/--channel or env SLACK_BOT_TOKEN / SLACK_CHANNEL')
        return 2
      end

      cwd = Dir.pwd
      title = args.title || "Codex run: #{File.basename(cwd)}"
      session_file = args.session_file ? Pathname(args.session_file) : find_latest_session_file(Pathname(args.sessions_dir))
      unless session_file&.exist?
        stderr.puts('ERROR: no Codex session log file found')
        return 2
      end
      root_text = build_root_text(
        title,
        cwd,
        user_name: args.user_name,
        session_id: session_id_from_path(session_file)
      )

      process_codex_log_stream(
        iter_follow_lines(
          session_file,
          poll_sec: args.poll_sec,
          once: args.once,
          start_at_end: true,
          sleep_func: method(:sleep)
        ),
        token: args.token,
        channel: args.channel,
        root_text:,
        user_name: args.user_name,
        include_tools: args.include_tools,
        throttle_sec: args.throttle_sec
      )
    rescue Interrupt
      stderr.puts('Stopped.')
      0
    end
  end
end
