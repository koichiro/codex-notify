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
      command = event['tool_input'] || event['command'] || event.dig('payload', 'command')
      if command.nil? || command.to_s.empty?
        payload = JSON.pretty_generate(event)
        return tool_text('tool', payload)
      end

      tool_text('tool', "$ #{command}")
    end

    def format_post_tool(event)
      output = event['tool_output'] || event['output'] || event.dig('payload', 'output')
      exit_code = event['exit_code'] || event.dig('payload', 'exit_code')
      stderr = event['stderr'] || event.dig('payload', 'stderr')

      parts = []
      parts << "[exit_code] #{exit_code}" unless exit_code.nil?
      parts << "[output]\n#{output}" unless output.nil? || output.to_s.empty?
      parts << "[stderr]\n#{stderr}" unless stderr.nil? || stderr.to_s.empty?
      parts = [JSON.pretty_generate(event)] if parts.empty?
      tool_text('tool', parts.join("\n\n"))
    end
  end
end
