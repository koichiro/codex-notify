# frozen_string_literal: true

require 'json'

module CodexNotify
  module LogEventParser
    module_function

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
        if obj['type'] == 'session_meta'
          payload = obj['payload']
          if payload.is_a?(Hash)
            value = payload['id']
            return value.to_s unless value.nil? || value.to_s.empty?
          end
        end

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
  end
end
