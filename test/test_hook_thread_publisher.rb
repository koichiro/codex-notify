# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'test_helper'
require_relative 'support/fake_slack_client'

class HookThreadPublisherTest < Minitest::Test
  include HookTestSupport

  def test_ensure_thread_creates_only_one_session_root
    with_publisher do |publisher, client, store|
      assert_equal '1000.01', publisher.ensure_thread(session_id: 'session-1', root_message: formatted_message('session root'))
      assert_equal '1000.01', publisher.ensure_thread(session_id: 'session-1', root_message: formatted_message('ignored root'))

      assert_equal [[render(formatted_message('session root')), nil]], client.posts
      assert_equal '1000.01', store.thread_ts_for('session-1')
    end
  end

  def test_ensure_thread_skips_an_empty_root
    with_publisher do |publisher, client, store|
      assert_nil publisher.ensure_thread(session_id: 'session-1', root_message: formatted_message(''))

      assert_empty client.posts
      assert_nil store.thread_ts_for('session-1')
    end
  end

  def test_publish_root_or_reply_creates_a_root_for_a_new_session
    with_publisher do |publisher, client, store|
      value = formatted_message('first prompt')
      assert_equal '1000.01', publisher.publish_root_or_reply(session_id: 'session-1', message: value)

      assert_equal [[render(value), nil]], client.posts
      assert_equal '1000.01', store.thread_ts_for('session-1')
    end
  end

  def test_publish_root_or_reply_posts_to_an_existing_thread
    with_publisher(initial_thread_ts: '1000.01') do |publisher, client, store|
      value = formatted_message('next prompt')
      assert_equal '1000.01', publisher.publish_root_or_reply(session_id: 'session-1', message: value)

      assert_equal [[render(value), '1000.01']], client.posts
      assert_equal '1000.01', store.thread_ts_for('session-1')
    end
  end

  def test_publish_reply_skips_a_session_without_a_thread
    with_publisher do |publisher, client, store|
      assert_nil publisher.publish_reply(
        session_id: 'session-1',
        message: formatted_message('assistant response'),
        recovery_root_message: formatted_message('session root')
      )

      assert_empty client.posts
      assert_nil store.thread_ts_for('session-1')
    end
  end

  def test_publish_root_or_reply_recovers_all_stale_thread_errors_without_duplicate_content
    CodexNotify::HookThreadPublisher::STALE_THREAD_ERROR_CODES.each do |error_code|
      client = FakeSlackClient.new do |_text, thread_ts|
        if thread_ts == 'stale-ts'
          raise CodexNotify::SlackClient::Error.new('stale thread', error_code:)
        end

        { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
      end
      value = formatted_message('recovered prompt')

      with_publisher(client:, initial_thread_ts: 'stale-ts') do |publisher, _client, store|
        assert_equal '2000.01', publisher.publish_root_or_reply(session_id: 'session-1', message: value)

        assert_equal [[render(value), 'stale-ts'], [render(value), nil]], client.posts
        assert_equal '2000.01', store.thread_ts_for('session-1')
      end
    end
  end

  def test_publish_reply_recreates_a_stale_thread_before_replaying_the_reply
    client = FakeSlackClient.new do |_text, thread_ts|
      if thread_ts == 'stale-ts'
        raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'thread_not_found')
      end

      { 'ok' => true, 'ts' => (thread_ts || '3000.01') }
    end
    reply = formatted_message('assistant response')
    root = formatted_message('session root')

    with_publisher(client:, initial_thread_ts: 'stale-ts') do |publisher, _client, store|
      assert_equal '3000.01', publisher.publish_reply(
        session_id: 'session-1',
        message: reply,
        recovery_root_message: root
      )

      assert_equal [
        [render(reply), 'stale-ts'],
        [render(root), nil],
        [render(reply), '3000.01']
      ], client.posts
      assert_equal '3000.01', store.thread_ts_for('session-1')
    end
  end

  def test_publish_reply_does_not_replay_without_a_recovery_root
    client = FakeSlackClient.new do |_text, thread_ts|
      raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'invalid_ts') if thread_ts == 'stale-ts'

      { 'ok' => true, 'ts' => 'unused' }
    end
    reply = formatted_message('assistant response')

    with_publisher(client:, initial_thread_ts: 'stale-ts') do |publisher, _client, store|
      assert_nil publisher.publish_reply(
        session_id: 'session-1',
        message: reply,
        recovery_root_message: nil
      )

      assert_equal [[render(reply), 'stale-ts']], client.posts
      assert_nil store.thread_ts_for('session-1')
    end
  end

  def test_non_stale_slack_errors_are_not_retried
    client = FakeSlackClient.new do |_text, _thread_ts|
      raise CodexNotify::SlackClient::Error.new('rate limited', error_code: 'ratelimited')
    end
    value = formatted_message('prompt')

    with_publisher(client:, initial_thread_ts: '1000.01') do |publisher, _client, store|
      error = assert_raises(CodexNotify::SlackClient::Error) do
        publisher.publish_root_or_reply(session_id: 'session-1', message: value)
      end

      assert_equal 'ratelimited', error.error_code
      assert_equal [[render(value), '1000.01']], client.posts
      assert_equal '1000.01', store.thread_ts_for('session-1')
    end
  end

  def test_stale_error_while_creating_a_root_is_not_retried
    client = FakeSlackClient.new do |_text, _thread_ts|
      raise CodexNotify::SlackClient::Error.new('invalid root', error_code: 'invalid_ts')
    end
    value = formatted_message('first prompt')

    with_publisher(client:) do |publisher, _client, store|
      assert_raises(CodexNotify::SlackClient::Error) do
        publisher.publish_root_or_reply(session_id: 'session-1', message: value)
      end

      assert_equal [[render(value), nil]], client.posts
      assert_nil store.thread_ts_for('session-1')
    end
  end

  def test_multi_chunk_root_uses_the_first_chunk_as_root_and_orders_the_rest_as_replies
    value = formatted_message('a' * 7_000)
    expected_parts = CodexNotify::MessageFormatter.chunks(value).to_a

    with_publisher do |publisher, client, store|
      assert_equal '1000.01', publisher.publish_root_or_reply(session_id: 'session-1', message: value)

      assert_equal expected_parts, client.posts.map(&:first)
      assert_nil client.posts.first.last
      assert client.posts.drop(1).all? { |(_part, thread_ts)| thread_ts == '1000.01' }
      assert_equal '1000.01', store.thread_ts_for('session-1')
    end
  end

  def test_multi_chunk_reply_preserves_order_in_the_existing_thread
    value = formatted_message('b' * 7_000)
    expected_parts = CodexNotify::MessageFormatter.chunks(value).to_a

    with_publisher(initial_thread_ts: '1000.01') do |publisher, client, _store|
      assert_equal '1000.01', publisher.publish_reply(
        session_id: 'session-1',
        message: value,
        recovery_root_message: formatted_message('session root')
      )

      assert_equal expected_parts, client.posts.map(&:first)
      assert client.posts.all? { |(_part, thread_ts)| thread_ts == '1000.01' }
    end
  end

  def test_reset_thread_clears_the_saved_timestamp
    with_publisher(initial_thread_ts: '1000.01') do |publisher, client, store|
      publisher.reset_thread(session_id: 'session-1')

      assert_nil store.thread_ts_for('session-1')
      assert_empty client.posts
    end
  end

  private

  def formatted_message(body)
    CodexNotify::MessageFormatter.message(title: 'title', body:, presentation: :plain)
  end

  def render(value)
    CodexNotify::MessageFormatter.chunks(value).to_a.fetch(0)
  end

  def with_publisher(client: FakeSlackClient.new, initial_thread_ts: nil)
    Dir.mktmpdir do |dir|
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))
      store.save_thread_ts('session-1', initial_thread_ts) if initial_thread_ts
      publisher = CodexNotify::HookThreadPublisher.new(client:, store:)
      yield publisher, client, store
    end
  end
end
