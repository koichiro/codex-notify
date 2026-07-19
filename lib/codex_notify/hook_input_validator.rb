# frozen_string_literal: true

require_relative 'hook_event'

module CodexNotify
  class HookInputError < StandardError; end

  module HookInputValidator
    EVENT_ALIASES = {
      'userpromptsubmit' => 'UserPromptSubmit',
      'pretooluse' => 'PreToolUse',
      'posttooluse' => 'PostToolUse',
      'permissionrequest' => 'PermissionRequest',
      'stop' => 'Stop',
      'sessionstart' => 'SessionStart'
    }.freeze
    SUPPORTED_EVENTS = EVENT_ALIASES.values.freeze

    module_function

    def validate(event_name:, payload:)
      raise HookInputError, 'hook payload must be a JSON object' unless payload.is_a?(Hash)

      normalized_event = validate_event_name(event_name, payload)
      session_id = validate_session_id(payload)
      attributes = normalize_event_payload(normalized_event, payload)
      HookEvent.new(
        name: immutable_copy(normalized_event),
        session_id: immutable_copy(session_id),
        cwd: immutable_copy(payload['cwd'] || Dir.pwd),
        source: nil,
        prompt: nil,
        tool_name: nil,
        tool_input: nil,
        tool_response: nil,
        assistant_message: nil,
        raw_payload: nil,
        **attributes
      )
    end

    def normalize_event_name(name)
      return nil unless name.is_a?(String)

      text = name.strip
      return nil if text.empty?
      return text if SUPPORTED_EVENTS.include?(text)

      EVENT_ALIASES[text.downcase.gsub(/[_\s-]/, '')] || text
    end

    def validate_event_name(event_name, payload)
      names = [event_name, payload['hook_event_name'], payload['event']].compact
      raise HookInputError, 'hook event name is required' if names.empty?

      normalized = names.map do |name|
        value = normalize_event_name(name)
        raise HookInputError, 'hook event name must be a non-empty string' if value.nil?
        raise HookInputError, 'unsupported hook event' unless SUPPORTED_EVENTS.include?(value)

        value
      end
      raise HookInputError, 'hook event names from arguments and payload do not match' unless normalized.uniq.one?

      normalized.first
    end
    private_class_method :validate_event_name

    def validate_session_id(payload)
      candidates = [
        payload['session_id'],
        payload['sessionId'],
        nested_session_id(payload)
      ].compact
      raise HookInputError, 'hook session ID is required' if candidates.empty?

      normalized = candidates.map do |value|
        unless value.is_a?(String) && !value.strip.empty?
          raise HookInputError, 'hook session ID must be a non-empty string'
        end

        value.strip
      end
      raise HookInputError, 'hook session IDs in payload do not match' unless normalized.uniq.one?

      normalized.first
    end
    private_class_method :validate_session_id

    def nested_session_id(payload)
      session = payload['session']
      return nil if session.nil?
      raise HookInputError, 'hook session must be an object' unless session.is_a?(Hash)

      session['id']
    end
    private_class_method :nested_session_id

    def normalize_event_payload(event_name, payload)
      case event_name
      when 'SessionStart'
        source = payload_value(payload, 'source')
        require_non_empty_string(source, event_name, 'source')
        { source: immutable_copy(source) }
      when 'UserPromptSubmit'
        prompt = payload_value(payload, 'prompt')
        require_non_empty_string(prompt, event_name, 'prompt')
        { prompt: immutable_copy(prompt) }
      when 'PreToolUse'
        tool_name = require_tool_name(payload, event_name)
        tool_input = normalize_pre_tool_input(payload, event_name)
        raw_payload = payload unless displayable_command?(tool_input['command'])
        { tool_name:, tool_input:, raw_payload: immutable_copy(raw_payload) }
      when 'PostToolUse'
        tool_name = require_tool_name(payload, event_name)
        tool_response = normalize_post_tool_response(payload, event_name)
        raw_payload = payload unless displayable_tool_response?(tool_response)
        { tool_name:, tool_response:, raw_payload: immutable_copy(raw_payload) }
      when 'PermissionRequest'
        tool_name = require_tool_name(payload, event_name)
        value = payload_value(payload, 'tool_input')
        require_hash(value, event_name, 'tool_input')
        tool_input = { 'description' => immutable_copy(value['description']) }.freeze
        { tool_name:, tool_input: }
      when 'Stop'
        value, present = payload_value_with_presence(payload, 'last_assistant_message')
        raise HookInputError, 'Stop requires last_assistant_message' unless present
        raise HookInputError, 'Stop last_assistant_message must be a string' unless value.is_a?(String)

        { assistant_message: immutable_copy(value) }
      end
    end
    private_class_method :normalize_event_payload

    def require_tool_name(payload, event_name)
      value = payload_value(payload, 'tool_name')
      require_non_empty_string(value, event_name, 'tool_name')
      immutable_copy(value)
    end
    private_class_method :require_tool_name

    def normalize_pre_tool_input(payload, event_name)
      value, present = payload_value_with_presence(payload, 'tool_input')
      if present
        valid = value.is_a?(Hash) || (value.is_a?(String) && !value.strip.empty?)
        raise HookInputError, "#{event_name} tool_input must be an object or non-empty string" unless valid

        command = value.is_a?(Hash) ? value['command'] : value
        return immutable_copy('command' => command)
      end

      command, command_present = payload_value_with_presence(payload, 'command')
      valid_command = (command.is_a?(Array) && !command.empty?) ||
                      (command.is_a?(String) && !command.strip.empty?)
      return immutable_copy('command' => command) if command_present && valid_command

      raise HookInputError, "#{event_name} requires tool_input or command"
    end
    private_class_method :normalize_pre_tool_input

    def normalize_post_tool_response(payload, event_name)
      value, present = payload_value_with_presence(payload, 'tool_response')
      if present && !value.is_a?(Hash) && !value.is_a?(String)
        raise HookInputError, "#{event_name} tool_response must be an object or string"
      end

      legacy_fields = %w[tool_output output exit_code stderr]
      legacy_present = legacy_fields.any? do |field|
        legacy_value, legacy_present = payload_value_with_presence(payload, field)
        legacy_present && !legacy_value.nil?
      end
      unless present || legacy_present
        raise HookInputError, "#{event_name} requires tool_response or a supported legacy result field"
      end

      response = value.is_a?(Hash) ? value : {}
      output = response['output'] || response['stdout'] || (value unless value.is_a?(Hash))
      output ||= payload_value(payload, 'tool_output') || payload_value(payload, 'output')
      exit_code = response['exit_code'] || response['exitCode'] || payload_value(payload, 'exit_code')
      stderr = response['stderr'] || payload_value(payload, 'stderr')

      immutable_copy('output' => output, 'exit_code' => exit_code, 'stderr' => stderr)
    end
    private_class_method :normalize_post_tool_response

    def displayable_command?(command)
      !command.nil? && !command.to_s.empty?
    end
    private_class_method :displayable_command?

    def displayable_tool_response?(response)
      !response['exit_code'].nil? ||
        (!response['output'].nil? && !response['output'].to_s.empty?) ||
        (!response['stderr'].nil? && !response['stderr'].to_s.empty?)
    end
    private_class_method :displayable_tool_response?

    def require_non_empty_string(value, event_name, field)
      return if value.is_a?(String) && !value.strip.empty?

      raise HookInputError, "#{event_name} requires non-empty #{field}"
    end
    private_class_method :require_non_empty_string

    def require_hash(value, event_name, field)
      return if value.is_a?(Hash)

      raise HookInputError, "#{event_name} requires #{field} to be an object"
    end
    private_class_method :require_hash

    def payload_value(payload, key)
      payload_value_with_presence(payload, key).first
    end
    private_class_method :payload_value

    def payload_value_with_presence(payload, key)
      return [payload[key], true] if payload.key?(key)

      nested = payload['payload']
      return [nested[key], true] if nested.is_a?(Hash) && nested.key?(key)

      [nil, false]
    end
    private_class_method :payload_value_with_presence

    def immutable_copy(value)
      case value
      when Hash
        value.to_h { |key, item| [immutable_copy(key), immutable_copy(item)] }.freeze
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
    private_class_method :immutable_copy
  end
end
