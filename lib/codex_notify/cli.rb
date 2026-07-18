#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'time'
require_relative 'config'
require_relative 'log_event_parser'
require_relative 'message_formatter'
require_relative 'session_log'
require_relative 'slack_client'
require_relative 'stream_processor'

module CodexNotify
  module CLI
    module_function

    def slack_post(token, channel, text, thread_ts = nil)
      SlackClient.new(token:, channel:).post(text, thread_ts:)
    end

    def main(argv = nil, stdin: nil, stderr: $stderr)
      args = CodexNotify::Config.parse_args(argv, stderr:)
      unless args.token && args.channel
        stderr.puts('ERROR: need --token/--channel or env SLACK_BOT_TOKEN / SLACK_CHANNEL')
        return 2
      end

      cwd = Dir.pwd
      title = args.title || "Codex run: #{File.basename(cwd)}"
      session_file = args.session_file ? Pathname(args.session_file) : CodexNotify::SessionLog.find_latest_session_file(Pathname(args.sessions_dir))
      unless session_file&.exist?
        stderr.puts('ERROR: no Codex session log file found')
        return 2
      end
      root_text = CodexNotify::MessageFormatter.build_root_text(
        title,
        cwd,
        user_name: args.user_name,
        session_id: CodexNotify::SessionLog.session_id_from_log(session_file) ||
          CodexNotify::SessionLog.session_id_from_path(session_file)
      )

      CodexNotify::StreamProcessor.process_codex_log_stream(
        CodexNotify::SessionLog.iter_follow_lines(
          session_file,
          poll_sec: args.poll_sec,
          once: args.once,
          start_at_end: !args.once,
          sleep_func: method(:sleep)
        ),
        token: args.token,
        channel: args.channel,
        root_text:,
        initial_prompt: args.prompt,
        user_name: args.user_name,
        include_tools: args.include_tools,
        throttle_sec: args.throttle_sec,
        post_func: method(:slack_post)
      )
    rescue Interrupt
      stderr.puts('Stopped.')
      0
    end
  end
end
