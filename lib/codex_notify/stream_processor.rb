# frozen_string_literal: true

require 'json'

module CodexNotify
  module StreamProcessor
    module_function

    def process_codex_log_stream(stream, token:, channel:, root_text:, initial_prompt: nil, user_name: 'user', include_tools: false,
                                 throttle_sec: 0.0, post_func:, sleep_func: Kernel.method(:sleep))
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

      unless initial_prompt.nil? || initial_prompt.empty?
        parts = CodexNotify::MessageFormatter.chunk_text(initial_prompt).to_a
        first_part = parts.shift
        initial_thread_ts = post_func.call(
          token,
          channel,
          CodexNotify::MessageFormatter.fmt_plain(user_name, first_part),
          nil
        ).fetch('ts').to_s
        thread_ts_by_session['__default__'] = initial_thread_ts
        sleep_func.call(throttle_sec)
        parts.each do |part|
          post_func.call(token, channel, CodexNotify::MessageFormatter.fmt_plain("#{user_name}(cont.)", part), initial_thread_ts)
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
