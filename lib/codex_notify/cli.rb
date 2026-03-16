#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'optparse'
require 'pathname'
require 'time'
require 'uri'

module CodexNotify
  module CLI
    SLACK_API = 'https://slack.com/api/chat.postMessage'
    DEFAULT_ENV_PATH = '.env'
    DEFAULT_SESSIONS_DIR = Pathname(File.expand_path('~/.codex/sessions'))

    Args = Struct.new(
      :env_file,
      :token,
      :channel,
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

    def chunk_text(text, max_len = 3500)
      normalized = text.gsub("\r\n", "\n")
      return enum_for(__method__, normalized, max_len) unless block_given?

      index = 0
      while index < normalized.length
        yield normalized[index, max_len]
        index += max_len
      end
    end

    def fmt_block(title, body)
      "*#{title}*\n```#{body}```"
    end

    def build_root_text(title, cwd)
      fmt_block(title, "Codex log monitoring started.\nCWD: #{cwd}")
    end

    def fmt_plain(title, body)
      "*#{title}*\n#{body}"
    end

    def getenv_any(keys)
      keys.each do |key|
        value = ENV[key]
        return value if value && !value.empty?
      end
      nil
    end

    def as_text(value)
      return '' if value.nil?
      return value if value.is_a?(String)
      return JSON.generate(value, ascii_only: false) if value.is_a?(Hash) || value.is_a?(Array)

      value.to_s
    end

    def pretty_json(value)
      JSON.pretty_generate(value, ascii_only: false)
    rescue StandardError
      as_text(value)
    end

    def format_tool_payload(payload)
      command = payload['command'] || payload['cmd'] || payload['argv']
      stdout = payload['stdout']
      stderr = payload['stderr']
      exit_code = payload['exit_code']

      if command.nil? && payload['info'].is_a?(Hash)
        info = payload['info']
        command = info['command'] || info['cmd'] || info['argv']
        stdout ||= info['stdout']
        stderr ||= info['stderr']
        exit_code = info['exit_code'] if exit_code.nil?
      end

      if !command.nil? || !stdout.nil? || !stderr.nil? || !exit_code.nil?
        command_text = command.is_a?(Array) ? command.map(&:to_s).join(' ') : (command || '').to_s
        parts = []
        parts << "$ #{command_text}" unless command_text.empty?
        parts << "[exit_code] #{exit_code}" unless exit_code.nil?
        parts << "\n[stdout]\n#{stdout}" if stdout && !stdout.empty?
        parts << "\n[stderr]\n#{stderr}" if stderr && !stderr.empty?
        rendered = parts.join("\n").strip
        return rendered.empty? ? pretty_json(payload) : rendered
      end

      %w[tool_name name tool function_name].each do |key|
        next unless payload[key]

        tool_name = payload[key]
        args = payload['arguments'] || payload['args'] || payload['input']
        result = payload['result'] || payload['output']
        parts = ["[tool] #{tool_name}"]
        parts << "[args]\n#{pretty_json(args)}" unless args.nil?
        parts << "[result]\n#{pretty_json(result)}" unless result.nil?
        return parts.join("\n")
      end

      pretty_json(payload)
    end

    def tool_event_type?(event_type)
      return false if event_type.nil? || event_type.to_s.empty?

      %w[
        command_execution
        shell_command
        tool_call
        tool_result
        tool
        mcp_tool_call
        mcp_tool_result
        mcp_call
        mcp_result
        sandbox_command
      ].include?(event_type.to_s)
    end

    def extract_events(obj)
      events = []

      if obj.is_a?(Array)
        obj.each { |item| events.concat(extract_events(item)) }
        return events
      end

      return events unless obj.is_a?(Hash)

      object_type = obj['type']
      if %w[input_text output_text].include?(object_type)
        text = as_text(obj['text'] || obj['content'])
        unless text.empty?
          kind = object_type == 'input_text' ? 'user' : 'assistant'
          events << [kind, text, object_type]
        end
        return events
      end

      payload = obj['payload']
      if payload.is_a?(Hash)
        payload_type = payload['type']

        if tool_event_type?(payload_type)
          events << ['tool', format_tool_payload(payload), 'tool']
          return events
        end

        if %w[input_text output_text].include?(payload_type)
          text = as_text(payload['text'] || payload['content'])
          unless text.empty?
            kind = payload_type == 'input_text' ? 'user' : 'assistant'
            events << [kind, text, payload_type]
          end
          return events
        end

        if payload_type == 'message'
          role = payload['role']
          content = payload['content'] || payload['parts']

          if content.is_a?(Array)
            content.each do |part|
              next unless part.is_a?(Hash)

              part_type = part['type']
              if %w[input_text output_text].include?(part_type)
                text = as_text(part['text'] || part['content'])
                unless text.empty?
                  kind = part_type == 'input_text' ? 'user' : 'assistant'
                  events << [kind, text, part_type]
                end
              elsif tool_event_type?(part_type)
                events << ['tool', format_tool_payload(part), 'tool']
              end
            end
          else
            text = as_text(payload['text'])
            if !text.empty? && %w[user assistant].include?(role)
              inferred = role == 'user' ? 'input_text' : 'output_text'
              events << [role, text, inferred]
            end
          end
          return events
        end

        if payload_type == 'user_message'
          text = as_text(payload['message'] || payload['text'])
          events << ['user', text, 'input_text'] unless text.empty?
          return events
        end

        if payload_type == 'agent_message'
          text = as_text(payload['message'] || payload['text'])
          events << ['assistant', text, 'output_text'] unless text.empty?
          return events
        end

        if payload_type == 'task_complete'
          text = as_text(payload['last_agent_message'])
          events << ['assistant', text, 'output_text'] unless text.empty?
          return events
        end

        nested_message = payload['message']
        if nested_message.is_a?(Hash) || nested_message.is_a?(Array)
          events.concat(extract_events(nested_message))
          return events
        end

        %w[tool tool_call tool_result command_execution command].each do |key|
          nested = payload[key]
          next unless nested.is_a?(Hash)

          nested_type = nested['type'] || key
          if tool_event_type?(nested_type) || %w[command_execution command].include?(key)
            events << ['tool', format_tool_payload(nested), 'tool']
          end
        end
      end

      %w[message item response_item response_message data].each do |key|
        nested = obj[key]
        events.concat(extract_events(nested)) if nested.is_a?(Hash) || nested.is_a?(Array)
      end

      events
    end

    def extract_session_id(obj)
      return nil if obj.nil?

      if obj.is_a?(Hash)
        %w[
          session_id
          sessionId
          conversation_id
          conversationId
          chat_id
          chatId
          thread_id
          threadId
        ].each do |key|
          value = obj[key]
          return value.to_s unless value.nil? || value.to_s.empty?
        end

        obj.each_value do |value|
          session_id = extract_session_id(value)
          return session_id if session_id
        end
      elsif obj.is_a?(Array)
        obj.each do |value|
          session_id = extract_session_id(value)
          return session_id if session_id
        end
      end

      nil
    end

    def build_parser
      options = Args.new(
        env_file: DEFAULT_ENV_PATH,
        token: nil,
        channel: nil,
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

    def iter_follow_lines(path, poll_sec: 1.0, once: false, start_at_end: true, sleep_func: Kernel.method(:sleep))
      return enum_for(__method__, path, poll_sec:, once:, start_at_end:, sleep_func:) unless block_given?

      Pathname(path).open('r:utf-8') do |handle|
        handle.seek(0, IO::SEEK_END) if start_at_end
        loop do
          line = handle.gets
          if line
            yield line
            next
          end
          break if once

          sleep_func.call(poll_sec)
        end
      end
    end

    def find_latest_session_file(sessions_dir)
      root = Pathname(sessions_dir)
      return nil unless root.exist?

      files = root.glob('**/*.jsonl').select(&:file?)
      return nil if files.empty?

      files.max_by { |path| path.stat.mtime.to_f }
    end

    def process_codex_log_stream(stream, token:, channel:, root_text:, include_tools: false, throttle_sec: 0.0,
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
              post_func.call(token, channel, fmt_plain('user', parts.first), thread_ts)
            else
              thread_ts = post_func.call(token, channel, fmt_plain('user', parts.first), nil).fetch('ts').to_s
              thread_ts_by_session[session_id] = thread_ts
            end
            sleep_func.call(throttle_sec)
            parts.drop(1).each do |part|
              post_func.call(token, channel, fmt_plain('user(cont.)', part), thread_ts)
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
      root_text = build_root_text(title, cwd)
      session_file = args.session_file ? Pathname(args.session_file) : find_latest_session_file(Pathname(args.sessions_dir))
      unless session_file&.exist?
        stderr.puts('ERROR: no Codex session log file found')
        return 2
      end

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
        include_tools: args.include_tools,
        throttle_sec: args.throttle_sec
      )
    rescue Interrupt
      stderr.puts('Stopped.')
      0
    end
  end
end
