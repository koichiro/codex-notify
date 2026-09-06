# frozen_string_literal: true

require 'json'
require_relative 'internal_task'

module CodexNotify
  module StreamProcessor
    module_function

    def process_codex_log_stream(stream, token:, channel:, root_message:, initial_prompt: nil, user_name: 'user', include_tools: false,
                                 throttle_sec: 0.0, post_func:, sleep_func: Kernel.method(:sleep), publisher: nil)
      suppressed_sessions = {}
      if InternalTask.title_prompt?(initial_prompt)
        suppressed_sessions['__default__'] = true
        initial_prompt = nil
      end
      stream = visible_log_events(stream, suppressed_sessions)

      if publisher
        return process_durable_stream(
          stream, root_message:, initial_prompt:, user_name:, include_tools:, publisher:
        )
      end

      last_sent_fingerprint = nil
      thread_ts_by_session = {}

      post_message = lambda do |message, thread_ts|
        CodexNotify::MessageFormatter.chunks(message).each do |part|
          post_func.call(token, channel, part, thread_ts)
          sleep_func.call(throttle_sec)
        end
      end

      post_root = lambda do |message|
        parts = CodexNotify::MessageFormatter.chunks(message).to_a
        response = post_func.call(token, channel, parts.shift, nil)
        thread_ts = response.fetch('ts').to_s
        sleep_func.call(throttle_sec)
        parts.each do |part|
          post_func.call(token, channel, part, thread_ts)
          sleep_func.call(throttle_sec)
        end
        thread_ts
      end

      post_root.call(root_message)

      unless initial_prompt.nil? || initial_prompt.empty?
        message = CodexNotify::MessageFormatter.message(title: user_name, body: initial_prompt, presentation: :plain)
        thread_ts_by_session['__default__'] = post_root.call(message)
      end

      stream.each do |session_id, extracted_events|
        extracted_events.each do |kind, text, part_type|
          next if text.empty?
          next if part_type == 'tool' && !include_tools

          fingerprint = "#{session_id}:#{part_type}:#{kind}:#{text[0, 240]}"
          next if fingerprint == last_sent_fingerprint

          last_sent_fingerprint = fingerprint
          title = kind == 'assistant' ? 'assistant' : kind
          thread_ts = thread_ts_by_session[session_id]
          presentation = %w[user assistant system].include?(title) ? :plain : :block
          message_title = kind == 'user' ? user_name : title
          message = CodexNotify::MessageFormatter.message(title: message_title, body: text, presentation:)

          if kind == 'user'
            if thread_ts
              post_message.call(message, thread_ts)
            else
              thread_ts = post_root.call(message)
              thread_ts_by_session[session_id] = thread_ts
            end
            next
          end

          post_message.call(message, thread_ts)
        end
      end

      0
    end

    def process_durable_stream(stream, root_message:, initial_prompt:, user_name:, include_tools:, publisher:)
      last_sent_fingerprint = nil
      monitor_key = publisher.key('log-monitor', Process.pid)
      publisher.publish_standalone(key: monitor_key, message: root_message)
      return 1 unless drain_succeeded?(publisher)

      unless initial_prompt.nil? || initial_prompt.empty?
        message = CodexNotify::MessageFormatter.message(title: user_name, body: initial_prompt, presentation: :plain)
        publisher.publish_root_or_reply(key: publisher.key('log', '__default__'), message:)
        return 1 unless drain_succeeded?(publisher)
      end

      stream.each do |session_id, extracted_events|
        extracted_events.each do |kind, body, part_type|
          next if body.empty?
          next if part_type == 'tool' && !include_tools

          fingerprint = "#{session_id}:#{part_type}:#{kind}:#{body[0, 240]}"
          next if fingerprint == last_sent_fingerprint

          last_sent_fingerprint = fingerprint
          title = kind == 'assistant' ? 'assistant' : kind
          presentation = %w[user assistant system].include?(title) ? :plain : :block
          message_title = kind == 'user' ? user_name : title
          message = CodexNotify::MessageFormatter.message(title: message_title, body:, presentation:)
          key = publisher.key('log', session_id)
          if kind == 'user'
            publisher.publish_root_or_reply(key:, message:)
          else
            publisher.publish_reply(key:, message:, recovery_root_message: message)
          end
          return 1 unless drain_succeeded?(publisher)
        end
      end

      0
    end

    def visible_log_events(stream, suppressed_sessions)
      Enumerator.new do |output|
        current_session = '__default__'
        stream.each do |raw|
          begin
            event = JSON.parse(raw)
          rescue JSON::ParserError
            next
          end
          session_id = LogEventParser.extract_session_id(event)
          current_session = session_id || current_session
          events = LogEventParser.extract_events(event).reject do |kind, text, _type|
            suppressed_sessions[current_session] = InternalTask.title_prompt?(text) if kind == 'user'
            suppressed_sessions[current_session]
          end
          output << [session_id || '__default__', events] unless events.empty?
        end
      end
    end

    def drain_succeeded?(publisher)
      result = publisher.drain
      result.failed.empty? && result.needs_review.empty?
    end
  end
end
