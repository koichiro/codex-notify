# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'hook_store'
require_relative 'slack_client'
require_relative 'slack_delivery_worker'
require_relative 'slack_outbox'

module CodexNotify
  module OutboxCommands
    module_function

    def run(action:, id:, outbox_dir:, token:, channel:, state_file:, stdout:, stderr:)
      outbox = SlackOutbox.new(outbox_dir)
      case action
      when :status
        outbox.status_rows.each { |row| stdout.puts(JSON.generate(row)) }
        0
      when :retry
        outbox.retry(id)
        0
      when :drain
        unless token && channel
          stderr.puts('ERROR: draining the outbox requires Slack token and channel configuration')
          return 2
        end
        store = HookStore.new(state_file)
        result = SlackDeliveryWorker.new(
          outbox:,
          client: SlackClient.new(token:, channel:),
          store:
        ).drain(channel:)
        failed = result.failed.any? || result.needs_review.any?
        stderr.puts('ERROR: Slack delivery requires outbox review; run --outbox-status') if failed
        failed ? 1 : 0
      end
    rescue SlackOutbox::Error => e
      stderr.puts("ERROR: #{e.message}")
      1
    end
  end
end
