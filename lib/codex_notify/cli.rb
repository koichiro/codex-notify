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
require_relative 'hook_store'
require_relative 'slack_outbox'
require_relative 'durable_slack_publisher'
require_relative 'outbox_commands'

module CodexNotify
  module CLI
    PostClient = Data.define(:token, :channel, :post_callable) do
      def post(text, thread_ts: nil)
        post_callable.call(token, channel, text, thread_ts)
      end
    end

    module_function

    def slack_post(token, channel, text, thread_ts = nil)
      SlackClient.new(token:, channel:).post(text, thread_ts:)
    end

    def main(argv = nil, stdin: nil, stderr: $stderr, stdout: $stdout)
      args = CodexNotify::Config.parse_args(argv, stderr:)
      if args.migrate_config
        return ConfigMigrator.new(app_root: Config.app_root, stdout:, stderr:).run(
          env_path: args.env_file,
          env_explicit: args.env_file_explicit,
          config_path: args.config_file,
          dry_run: args.dry_run
        )
      end
      if args.outbox_action
        return OutboxCommands.run(
          action: args.outbox_action,
          id: args.outbox_id,
          outbox_dir: args.outbox_dir,
          token: args.token,
          channel: args.channel,
          state_file: Pathname(args.outbox_dir).join('thread-state.json'),
          stdout:,
          stderr:
        )
      end
      unless args.token && args.channel
        stderr.puts('ERROR: need --token/--channel or a Slack destination from environment or config file')
        return 2
      end

      cwd = Dir.pwd
      title = args.title || "Codex run: #{File.basename(cwd)}"
      session_file = args.session_file ? Pathname(args.session_file) : CodexNotify::SessionLog.find_latest_session_file(Pathname(args.sessions_dir))
      unless session_file&.exist?
        stderr.puts('ERROR: no Codex session log file found')
        return 2
      end
      root_message = CodexNotify::MessageFormatter.build_root_message(
        title,
        cwd,
        user_name: args.user_name,
        session_id: CodexNotify::SessionLog.session_id_from_log(session_file) ||
          CodexNotify::SessionLog.session_id_from_path(session_file)
      )
      outbox = SlackOutbox.new(args.outbox_dir)
      store = HookStore.new(Pathname(args.outbox_dir).join('thread-state.json'))
      publisher = DurableSlackPublisher.new(
        client: PostClient.new(args.token, args.channel, method(:slack_post)),
        store:,
        outbox:,
        channel: args.channel,
        throttle_sec: args.throttle_sec
      )

      code = CodexNotify::StreamProcessor.process_codex_log_stream(
        CodexNotify::SessionLog.iter_follow_lines(
          session_file,
          poll_sec: args.poll_sec,
          once: args.once,
          start_at_end: !args.once,
          sleep_func: method(:sleep)
        ),
        token: args.token,
        channel: args.channel,
        root_message:,
        initial_prompt: args.prompt,
        user_name: args.user_name,
        include_tools: args.include_tools,
        throttle_sec: args.throttle_sec,
        post_func: method(:slack_post),
        publisher:
      )
      stderr.puts('ERROR: Slack delivery requires outbox review; run --outbox-status') if code == 1
      code
    rescue Interrupt
      stderr.puts('Stopped.')
      0
    rescue SlackOutbox::Error => e
      stderr.puts("ERROR: #{e.message}")
      1
    rescue Config::Error, ConfigMigrator::Error, OptionParser::ParseError => e
      stderr.puts("ERROR: #{e.message}")
      2
    end
  end
end
