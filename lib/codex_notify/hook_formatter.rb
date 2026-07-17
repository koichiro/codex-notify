# frozen_string_literal: true

require_relative 'message_formatter'

module CodexNotify
  module HookFormatter
    module_function

    def session_root_text(title:, cwd:, session_id:, user_name:)
      body = [
        'Codex hook notification started.',
        "CWD: #{cwd}",
        "User: #{user_name}",
        "Session ID: #{session_id}"
      ].join("\n")
      MessageFormatter.fmt_block(title, body)
    end

    def prompt_text(user_name:, prompt:)
      MessageFormatter.fmt_plain(user_name, prompt.to_s)
    end

    def assistant_text(message)
      MessageFormatter.fmt_plain('assistant', message.to_s)
    end

    def tool_text(title, body)
      MessageFormatter.fmt_block(title, body.to_s)
    end

    def format_pre_tool(event)
      tool_input = event['tool_input']
      command = if tool_input.is_a?(Hash)
                  tool_input['command']
                else
                  tool_input
                end
      command ||= event['command'] || event.dig('payload', 'command')
      if command.nil? || command.to_s.empty?
        payload = JSON.pretty_generate(event)
        return tool_text('tool', payload)
      end

      tool_text('tool', "$ #{command}")
    end

    def format_post_tool(event)
      tool_response = event['tool_response']
      response = tool_response.is_a?(Hash) ? tool_response : {}

      output = response['output'] || response['stdout'] || tool_response
      output ||= event['tool_output'] || event['output'] || event.dig('payload', 'output')
      exit_code = response['exit_code'] || response['exitCode']
      exit_code ||= event['exit_code'] || event.dig('payload', 'exit_code')
      stderr = response['stderr'] || event['stderr'] || event.dig('payload', 'stderr')

      parts = []
      parts << "[exit_code] #{exit_code}" unless exit_code.nil?
      parts << "[output]\n#{output}" unless output.nil? || output.to_s.empty?
      parts << "[stderr]\n#{stderr}" unless stderr.nil? || stderr.to_s.empty?
      parts = [JSON.pretty_generate(event)] if parts.empty?
      tool_text('tool', parts.join("\n\n"))
    end

    def format_permission_request(event)
      tool_name = event['tool_name'] || event.dig('payload', 'tool_name') || 'tool'
      tool_input = event['tool_input'] || event.dig('payload', 'tool_input')
      description = tool_input['description'] if tool_input.is_a?(Hash)
      description ||= 'Codex is waiting for your approval.'
      tool_text("approval required: #{tool_name}", description)
    end
  end
end
