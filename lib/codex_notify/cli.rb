#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'pathname'
require 'time'
require 'uri'
require_relative 'config'
require_relative 'log_event_parser'
require_relative 'message_formatter'
require_relative 'session_log'
require_relative 'stream_processor'

module CodexNotify
  module CLI
    SLACK_API = 'https://slack.com/api/chat.postMessage'

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

    def load_env_file(*args, **kwargs)
      CodexNotify::Config.load_env_file(*args, **kwargs)
    end

    def system_user_name(*args, **kwargs)
      CodexNotify::Config.system_user_name(*args, **kwargs)
    end

    def getenv_any(*args, **kwargs)
      CodexNotify::Config.getenv_any(*args, **kwargs)
    end

    def build_parser(*args, **kwargs)
      CodexNotify::Config.build_parser(*args, **kwargs)
    end

    def parse_args(*args, **kwargs)
      CodexNotify::Config.parse_args(*args, **kwargs)
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
