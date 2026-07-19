# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class OutboxCommandsTest < Minitest::Test
  def test_status_does_not_print_message_text_or_require_credentials
    Dir.mktmpdir do |dir|
      outbox_dir = Pathname(dir).join('outbox')
      outbox = CodexNotify::SlackOutbox.new(outbox_dir)
      id = outbox.enqueue(
        channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone,
        chunks: ['private notification']
      )
      stdout = StringIO.new

      code = CodexNotify::HookCLI.main(
        ['--env-file', 'missing.env', '--outbox-dir', outbox_dir.to_s, '--outbox-status'],
        stdin: StringIO.new, stdout:, stderr: StringIO.new
      )

      assert_equal 0, code
      assert_includes stdout.string, id
      refute_includes stdout.string, 'private notification'
    end
  end

  def test_retry_moves_a_failed_job_back_to_pending
    Dir.mktmpdir do |dir|
      outbox_dir = Pathname(dir).join('outbox')
      outbox = CodexNotify::SlackOutbox.new(outbox_dir)
      id = outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone, chunks: ['message'])
      outbox.move(outbox.jobs.fetch(0), :failed)

      code = CodexNotify::HookCLI.main(
        ['--env-file', 'missing.env', '--outbox-dir', outbox_dir.to_s, '--retry-outbox', id],
        stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new
      )

      assert_equal 0, code
      assert_equal id, outbox.jobs.fetch(0)['id']
    end
  end

  def test_manual_drain_requires_credentials
    Dir.mktmpdir do |dir|
      stderr = StringIO.new
      code = CodexNotify::HookCLI.main(
        ['--env-file', 'missing.env', '--outbox-dir', Pathname(dir).join('outbox').to_s, '--drain-outbox'],
        stdin: StringIO.new, stdout: StringIO.new, stderr:
      )

      assert_equal 2, code
      assert_includes stderr.string, 'requires Slack token and channel'
    end
  end
end
