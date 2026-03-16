# frozen_string_literal: true

require 'json'

module CodexNotify
  module StreamProcessor
    module_function

    def process_events(stream, token:, channel:, root_text:, initial_prompt: nil, include_tools: false,
                       throttle_sec: 0.0, post_func:, sleep_func: Kernel.method(:sleep))
      root_res = post_func.call(token, channel, root_text, nil)
      thread_ts = root_res.fetch('ts').to_s
      sleep_func.call(throttle_sec)

      turn_idx = 0

      post_thread = lambda do |title, body|
        CodexNotify::MessageFormatter.chunk_text(body).each do |part|
          post_func.call(token, channel, CodexNotify::MessageFormatter.fmt_block(title, part), thread_ts)
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
                                 post_func:, sleep_func: Kernel.method(:sleep))
      post_func.call(token, channel, root_text, nil)
      sleep_func.call(throttle_sec)
      last_sent_fingerprint = nil
      thread_ts_by_session = {}

      post_thread = lambda do |title, body, thread_ts|
        CodexNotify::MessageFormatter.chunk_text(body).each do |part|
          formatter = %w[user assistant system].include?(title) ? CodexNotify::MessageFormatter.method(:fmt_plain) : CodexNotify::MessageFormatter.method(:fmt_block)
          post_func.call(token, channel, formatter.call(title, part), thread_ts)
          sleep_func.call(throttle_sec)
        end
      end

      stream.each do |raw|
        line = raw.strip
        next if line.empty?

        event = JSON.parse(line)
        session_id = CodexNotify::LogEventParser.extract_session_id(event) || '__default__'
        extracted_events = CodexNotify::LogEventParser.extract_events(event)
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
            parts = CodexNotify::MessageFormatter.chunk_text(text).to_a
            next if parts.empty?

            if thread_ts
              post_func.call(token, channel, CodexNotify::MessageFormatter.fmt_plain(user_name, parts.first), thread_ts)
            else
              thread_ts = post_func.call(token, channel, CodexNotify::MessageFormatter.fmt_plain(user_name, parts.first), nil).fetch('ts').to_s
              thread_ts_by_session[session_id] = thread_ts
            end
            sleep_func.call(throttle_sec)
            parts.drop(1).each do |part|
              post_func.call(token, channel, CodexNotify::MessageFormatter.fmt_plain("#{user_name}(cont.)", part), thread_ts)
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
  end
end
