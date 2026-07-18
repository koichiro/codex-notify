# frozen_string_literal: true

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
      validate_event_payload(normalized_event, payload)
      [normalized_event, session_id]
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

    def validate_event_payload(event_name, payload)
      case event_name
      when 'SessionStart'
        require_non_empty_string(payload_value(payload, 'source'), event_name, 'source')
      when 'UserPromptSubmit'
        require_non_empty_string(payload_value(payload, 'prompt'), event_name, 'prompt')
      when 'PreToolUse'
        require_tool_name(payload, event_name)
        require_pre_tool_input(payload, event_name)
      when 'PostToolUse'
        require_tool_name(payload, event_name)
        require_post_tool_response(payload, event_name)
      when 'PermissionRequest'
        require_tool_name(payload, event_name)
        value = payload_value(payload, 'tool_input')
        require_hash(value, event_name, 'tool_input')
      when 'Stop'
        value, present = payload_value_with_presence(payload, 'last_assistant_message')
        raise HookInputError, 'Stop requires last_assistant_message' unless present
        raise HookInputError, 'Stop last_assistant_message must be a string' unless value.is_a?(String)
      end
    end
    private_class_method :validate_event_payload

    def require_tool_name(payload, event_name)
      require_non_empty_string(payload_value(payload, 'tool_name'), event_name, 'tool_name')
    end
    private_class_method :require_tool_name

    def require_pre_tool_input(payload, event_name)
      value, present = payload_value_with_presence(payload, 'tool_input')
      if present
        valid = value.is_a?(Hash) || (value.is_a?(String) && !value.strip.empty?)
        return if valid

        raise HookInputError, "#{event_name} tool_input must be an object or non-empty string"
      end

      command, command_present = payload_value_with_presence(payload, 'command')
      valid_command = (command.is_a?(Array) && !command.empty?) ||
                      (command.is_a?(String) && !command.strip.empty?)
      return if command_present && valid_command

      raise HookInputError, "#{event_name} requires tool_input or command"
    end
    private_class_method :require_pre_tool_input

    def require_post_tool_response(payload, event_name)
      value, present = payload_value_with_presence(payload, 'tool_response')
      return if present && (value.is_a?(Hash) || value.is_a?(String))

      legacy_fields = %w[tool_output output exit_code stderr]
      return if legacy_fields.any? do |field|
        legacy_value, legacy_present = payload_value_with_presence(payload, field)
        legacy_present && !legacy_value.nil?
      end

      raise HookInputError, "#{event_name} requires tool_response or a supported legacy result field"
    end
    private_class_method :require_post_tool_response

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
  end
end
