# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'test_helper'

class SlackOutboxTest < Minitest::Test
  def test_enqueue_redacts_persisted_chunks_and_reports_safe_status
    with_outbox do |outbox|
      id = outbox.enqueue(
        channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone,
        chunks: ['SLACK_BOT_TOKEN=xoxb-secret']
      )

      job = outbox.jobs.fetch(0)
      assert_equal id, job['id']
      assert_includes job['message_chunks'].fetch(0), CodexNotify::SecretProtection::REDACTED
      refute_includes job['message_chunks'].fetch(0), 'xoxb-secret'
      assert_equal id, outbox.status_rows.fetch(0).fetch(:id)
      refute_includes JSON.generate(outbox.status_rows), 'SLACK_BOT_TOKEN'
      assert_equal 0o600, File.stat(outbox.path.join("pending/#{id}.json")).mode & 0o777
    end
  end

  def test_pending_root_and_complete
    with_outbox do |outbox|
      outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 2, action: :root_or_reply, chunks: ['one'])
      job = outbox.jobs.fetch(0)

      assert outbox.pending_root?('session', generation: 2)
      refute outbox.pending_root?('session', generation: 1)
      outbox.complete(job)
      assert_empty outbox.jobs
    end
  end

  def test_move_and_retry
    with_outbox do |outbox|
      id = outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :reply, chunks: ['one'])
      job = outbox.jobs.fetch(0)
      job['last_error'] = { 'code' => 'invalid_auth' }
      outbox.update(job)
      outbox.move(job, :failed)

      assert_empty outbox.jobs
      assert_equal 'invalid_auth', outbox.status_rows.fetch(0).fetch(:error)
      outbox.retry(id)
      assert_equal id, outbox.jobs.fetch(0)['id']
      assert_equal 0, outbox.jobs.fetch(0)['ambiguous_attempt_count']
      assert_raises(CodexNotify::SlackOutbox::Error) { outbox.retry('missing') }
    end
  end

  def test_drain_lock_is_nonblocking
    with_outbox do |outbox|
      nested = nil
      assert outbox.try_drain_lock { nested = outbox.try_drain_lock { flunk } }
      refute nested
    end
  end

  private

  def with_outbox
    Dir.mktmpdir do |dir|
      yield CodexNotify::SlackOutbox.new(Pathname(dir).join('outbox'))
    end
  end
end
