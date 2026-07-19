# frozen_string_literal: true

require 'json'
require_relative 'hook_config'
require_relative 'hook_input_validator'
require_relative 'hook_runner'
require_relative 'message_formatter'
require_relative 'outbox_commands'

module CodexNotify
  module HookCLI
    MAX_STDIN_BYTES = 1_048_576

    module_function

    def main(argv = nil, stdin: $stdin, stderr: $stderr, stdout: $stdout,
             runner_factory: HookRunner.method(:new))
      args = HookConfig.parse_args(argv, stderr:)

      if args.outbox_action
        return OutboxCommands.run(
          action: args.outbox_action,
          id: args.outbox_id,
          outbox_dir: args.outbox_dir,
          token: args.token,
          channel: args.channel,
          state_file: args.state_file,
          stdout:,
          stderr:
        )
      end

      unless args.token && args.channel
        stderr.puts('ERROR: need --token/--channel or a Slack destination from environment or config file')
        return 2
      end

      payload = parse_stdin(stdin)
      event = HookInputValidator.validate(event_name: args.event_name, payload:)

      runner = runner_factory.call(
        token: args.token,
        channel: args.channel,
        user_name: args.user_name,
        title: args.title,
        state_file: args.state_file,
        outbox_dir: args.outbox_dir,
        mode: args.mode,
        stdout: stdout
      )
      code = runner.run(event:)
      stderr.puts('ERROR: Slack delivery requires outbox review; run --outbox-status') if code == 1
      code
    rescue Interrupt
      0
    rescue HookInputError => e
      stderr.puts("ERROR: #{e.message}")
      2
    rescue HookConfig::Error, OptionParser::ParseError => e
      stderr.puts("ERROR: #{e.message}")
      2
    rescue StandardError => e
      stderr.puts("ERROR: #{e.class}: #{e.message}")
      1
    end

    def parse_stdin(stdin)
      raw = stdin.read(MAX_STDIN_BYTES + 1).to_s
      if raw.bytesize > MAX_STDIN_BYTES
        raise HookInputError, "hook stdin exceeds maximum size of #{MAX_STDIN_BYTES} bytes"
      end
      raise HookInputError, 'hook stdin is empty' if raw.strip.empty?

      payload = JSON.parse(raw)
      raise HookInputError, 'hook payload must be a JSON object' unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError
      raise HookInputError, 'hook stdin is not valid JSON'
    end
  end
end
