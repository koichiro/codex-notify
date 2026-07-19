# frozen_string_literal: true

require 'json'
require_relative 'message_formatter'

module CodexNotify
  module HookFormatter
    module_function

    def session_root_text(event, title:, user_name:)
      body = [
        'Codex hook notification started.',
        "CWD: #{event.cwd}",
        "User: #{user_name}",
        "Session ID: #{event.session_id}"
      ].join("\n")
      MessageFormatter.fmt_block(title, body)
    end

    def prompt_text(event, user_name:)
      MessageFormatter.fmt_plain(user_name, event.prompt.to_s)
    end

    def assistant_text(event)
      MessageFormatter.fmt_plain('assistant', event.assistant_message.to_s)
    end

    def tool_text(title, body)
      MessageFormatter.fmt_block(title, body.to_s)
    end

    def format_pre_tool(event)
      command = event.tool_input['command']
      if command.nil? || command.to_s.empty?
        payload = JSON.pretty_generate(event.raw_payload)
        return tool_text('tool', payload)
      end

      tool_text('tool', "$ #{command}")
    end

    def format_post_tool(event)
      output = event.tool_response['output']
      exit_code = event.tool_response['exit_code']
      stderr = event.tool_response['stderr']

      parts = []
      parts << "[exit_code] #{exit_code}" unless exit_code.nil?
      parts << "[output]\n#{output}" unless output.nil? || output.to_s.empty?
      parts << "[stderr]\n#{stderr}" unless stderr.nil? || stderr.to_s.empty?
      parts = [JSON.pretty_generate(event.raw_payload)] if parts.empty?
      tool_text('tool', parts.join("\n\n"))
    end

    def format_permission_request(event)
      description = event.tool_input['description']
      description ||= 'Codex is waiting for your approval.'
      tool_text("approval required: #{event.tool_name}", description)
    end
  end
end
