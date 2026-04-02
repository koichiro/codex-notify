# frozen_string_literal: true

require 'json'
require_relative 'hook_config'
require_relative 'hook_runner'
require_relative 'message_formatter'

module CodexNotify
  module HookCLI
    module_function

    def main(argv = nil, stdin: $stdin, stderr: $stderr, stdout: $stdout)
      args = HookConfig.parse_args(argv)

      unless args.token && args.channel
        stderr.puts('ERROR: need --token/--channel or env SLACK_BOT_TOKEN / SLACK_CHANNEL')
        return 2
      end

      payload = parse_stdin(stdin)
      event_name = args.event_name || payload['hook_event_name'] || payload['event']

      runner = HookRunner.new(
        token: args.token,
        channel: args.channel,
        user_name: args.user_name,
        title: args.title,
        state_file: args.state_file,
        stdout: stdout
      )
      runner.run(event_name:, payload:)
    rescue Interrupt
      stdout.puts(JSON.generate({ continue: true }))
      0
    rescue StandardError => e
      stderr.puts("ERROR: #{e.class}: #{e.message}")
      1
    end

    def parse_stdin(stdin)
      raw = stdin.read.to_s
      return {} if raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end
  end
end
