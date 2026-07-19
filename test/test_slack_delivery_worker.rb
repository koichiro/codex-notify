# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_helper'
require_relative 'support/fake_slack_client'

class SlackDeliveryWorkerTest < Minitest::Test
  FakeSlackClient = HookTestSupport::FakeSlackClient
  def test_delivers_a_multi_chunk_root_and_persists_thread
    with_worker do |outbox, worker, client, store|
      outbox.enqueue(
        channel: 'C123', ordering_key: 'session', generation: 0, action: :root_or_reply,
        chunks: %w[first second], recovery_chunks: %w[first second]
      )

      result = worker.drain(channel: 'C123')

      assert_equal 1, result.delivered.size
      assert_equal [['first', nil], ['second', '1000.01']], client.posts
      assert_equal '1000.01', store.thread_ts_for('session')
      assert_empty outbox.jobs
    end
  end

  def test_retries_a_definite_rate_limit_immediately
    attempts = 0
    client = FakeSlackClient.new do |_text, thread_ts|
      attempts += 1
      if attempts == 1
        raise CodexNotify::SlackClient::Error.new('rate limited', retryable: true, retry_after: 0)
      end
      { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
    end

    with_worker(client:, sleeper: ->(_delay) {}) do |outbox, worker, _client, _store|
      outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone, chunks: ['message'])
      result = worker.drain(channel: 'C123')

      assert_equal 2, attempts
      assert_equal 1, result.delivered.size
    end
  end

  def test_permanent_error_moves_job_to_failed
    client = FakeSlackClient.new do |_text, _thread_ts|
      raise CodexNotify::SlackClient::Error.new('invalid auth', error_code: 'invalid_auth')
    end

    with_worker(client:) do |outbox, worker, _client, _store|
      id = outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone, chunks: ['message'])
      result = worker.drain(channel: 'C123')

      assert_equal [id], result.failed
      assert_equal 'failed', outbox.status_rows.fetch(0).fetch(:status)
    end
  end

  def test_ambiguous_errors_eventually_need_review
    current = Time.utc(2026, 7, 19)
    clock = -> { current }
    client = FakeSlackClient.new do |_text, _thread_ts|
      raise CodexNotify::SlackClient::Error.new('unknown', retryable: true, ambiguous: true)
    end

    with_worker(client:, clock:, random: Random.new(1)) do |outbox, worker, _client, _store|
      id = outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone, chunks: ['message'])
      3.times do
        worker.drain(channel: 'C123')
        current += 10
      end

      assert_equal id, outbox.jobs(:needs_review).fetch(0)['id']
    end
  end

  def test_generation_change_cancels_an_old_job
    with_worker do |outbox, worker, client, store|
      outbox.enqueue(channel: 'C123', ordering_key: 'session', generation: 0, action: :standalone, chunks: ['old'])
      store.advance_generation('session')

      assert_equal 1, worker.drain(channel: 'C123').delivered.size
      assert_empty client.posts
    end
  end

  private

  def with_worker(client: FakeSlackClient.new, clock: -> { Time.now.utc }, sleeper: ->(_delay) {}, random: Random.new(1))
    Dir.mktmpdir do |dir|
      outbox = CodexNotify::SlackOutbox.new(Pathname(dir).join('outbox'), clock:)
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))
      worker = CodexNotify::SlackDeliveryWorker.new(
        outbox:, client:, store:, clock:, sleeper:, random:
      )
      yield outbox, worker, client, store
    end
  end
end
