# frozen_string_literal: true

require 'json'
require_relative 'message_formatter'

module CodexNotify
  module HookFormatter
    module_function

    def session_root_message(event, title:, user_name:)
      body = [
        'Codex hook notification started.',
        "CWD: #{event.cwd}",
        "User: #{user_name}",
        "Session ID: #{event.session_id}"
      ].join("\n")
      tool_message(title, body)
    end

    def prompt_message(event, user_name:)
      MessageFormatter.message(title: user_name, body: event.prompt, presentation: :plain)
    end

    def assistant_message(event)
      MessageFormatter.message(title: 'assistant', body: event.assistant_message, presentation: :plain)
    end

    def tool_message(title, body)
      MessageFormatter.message(title:, body:, presentation: :block)
    end

    def pre_tool_message(event)
      command = event.tool_input['command']
      if command.nil? || command.to_s.empty?
        payload = JSON.pretty_generate(event.raw_payload)
        return tool_message('tool', payload)
      end

      tool_message('tool', "$ #{command}")
    end

    def post_tool_message(event)
      output = event.tool_response['output']
      exit_code = event.tool_response['exit_code']
      stderr = event.tool_response['stderr']

      parts = []
      parts << "[exit_code] #{exit_code}" unless exit_code.nil?
      parts << "[output]\n#{output}" unless output.nil? || output.to_s.empty?
      parts << "[stderr]\n#{stderr}" unless stderr.nil? || stderr.to_s.empty?
      parts = [JSON.pretty_generate(event.raw_payload)] if parts.empty?
      tool_message('tool', parts.join("\n\n"))
    end

    def permission_request_message(event)
      description = event.tool_input['description']
      description ||= 'Codex is waiting for your approval.'
      tool_message("approval required: #{event.tool_name}", description)
    end
  end
end
