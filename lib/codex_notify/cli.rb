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

    def process_events(stream, token:, channel:, root_text:, initial_prompt: nil, include_tools: false,
                       throttle_sec: 0.0, post_func: method(:slack_post), sleep_func: Kernel.method(:sleep))
      root_res = post_func.call(token, channel, root_text, nil)
      thread_ts = root_res.fetch('ts').to_s
      sleep_func.call(throttle_sec)

      turn_idx = 0

      post_thread = lambda do |title, body|
        chunk_text(body).each do |part|
          post_func.call(token, channel, fmt_block(title, part), thread_ts)
          sleep_func.call(throttle_sec)
        end
      end

      post_thread.call('user', initial_prompt) if initial_prompt

      stream.each_line do |raw|
        line = raw.strip
        next if line.empty?

        event = JSON.parse(line)
        event_type = event['type']

        if event_type == 'turn.started'
          turn_idx += 1
          next
        end

        if event_type == 'turn.failed'
          post_thread.call('system', "turn #{turn_idx} failed")
          next
        end

        next unless event_type == 'item.completed'

        item = event['item'] || {}
        item_type = item['type'] || item['item_type']

        if %w[agent_message assistant_message assistant].include?(item_type)
          text = item['text'] || item['content'] || ''
          post_thread.call('assistant', text.empty? ? JSON.generate(item, ascii_only: false) : text)
          next
        end

        if %w[user_message user].include?(item_type)
          text = item['text'] || item['content'] || ''
          post_thread.call('user', text.empty? ? JSON.generate(item, ascii_only: false) : text)
          next
        end

        next unless include_tools

        if item_type == 'command_execution'
          command = item['command'] || item['cmd'] || ''
          exit_code = item['exit_code']
          stdout = item['stdout'] || ''
          stderr = item['stderr'] || ''
          body = "COMMAND:\n#{command}\n\nEXIT_CODE: #{exit_code}\n\nSTDOUT:\n#{stdout}\n\nSTDERR:\n#{stderr}"
          post_thread.call("command_execution (turn #{turn_idx})", body)
          next
        end

        if item_type == 'file_change'
          post_thread.call("file_change (turn #{turn_idx})", JSON.generate(item, ascii_only: false))
          next
        end

        if item_type == 'web_search'
          post_thread.call("web_search (turn #{turn_idx})", JSON.generate(item, ascii_only: false))
          next
        end

        post_thread.call("item.completed (#{item_type}) (turn #{turn_idx})", JSON.generate(item, ascii_only: false))
      rescue JSON::ParserError
        next
      end

      post_thread.call('Codex run finished', 'EOF')
      0
    end

    def process_codex_log_stream(stream, token:, channel:, root_text:, user_name: 'user', include_tools: false, throttle_sec: 0.0,
                                 post_func: method(:slack_post), sleep_func: Kernel.method(:sleep))
      post_func.call(token, channel, root_text, nil)
      sleep_func.call(throttle_sec)
      last_sent_fingerprint = nil
      thread_ts_by_session = {}

      post_thread = lambda do |title, body, thread_ts|
        chunk_text(body).each do |part|
          formatter = %w[user assistant system].include?(title) ? method(:fmt_plain) : method(:fmt_block)
          post_func.call(token, channel, formatter.call(title, part), thread_ts)
          sleep_func.call(throttle_sec)
        end
      end

      stream.each do |raw|
        line = raw.strip
        next if line.empty?

        event = JSON.parse(line)
        session_id = extract_session_id(event) || '__default__'
        extracted_events = extract_events(event)
        next if extracted_events.empty?

        extracted_events.each do |kind, text, part_type|
          next if text.empty?
          next if part_type == 'tool' && !include_tools

          fingerprint = "#{session_id}:#{part_type}:#{kind}:#{text[0, 240]}"
          next if fingerprint == last_sent_fingerprint

          last_sent_fingerprint = fingerprint
          title = kind == 'assistant' ? 'assistant' : kind
          thread_ts = thread_ts_by_session[session_id]

          if kind == 'user'
            parts = chunk_text(text).to_a
            next if parts.empty?

            if thread_ts
              post_func.call(token, channel, fmt_plain(user_name, parts.first), thread_ts)
            else
              thread_ts = post_func.call(token, channel, fmt_plain(user_name, parts.first), nil).fetch('ts').to_s
              thread_ts_by_session[session_id] = thread_ts
            end
            sleep_func.call(throttle_sec)
            parts.drop(1).each do |part|
              post_func.call(token, channel, fmt_plain("#{user_name}(cont.)", part), thread_ts)
              sleep_func.call(throttle_sec)
            end
            next
          end

          post_thread.call(title, text, thread_ts)
        end
      rescue JSON::ParserError
        next
      end

      0
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
