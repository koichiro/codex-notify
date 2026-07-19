# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'
require_relative 'support/fake_slack_client'

class CodexNotifyStreamProcessorTest < Minitest::Test
  FakeSlackClient = HookTestSupport::FakeSlackClient
  StreamProcessor = CodexNotify::StreamProcessor
  ROOT_MESSAGE = CodexNotify::MessageFormatter.message(title: 'root', body: 'root', presentation: :plain)

  def test_process_codex_log_stream_posts_initial_prompt_as_user_root
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "123.45#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"agent_message","message":"working on it"}}')

    StreamProcessor.process_codex_log_stream(
      events,
      token: 'xoxb-token',
      channel: 'C123',
      root_message: ROOT_MESSAGE,
      initial_prompt: 'Investigate failing tests',
      user_name: 'koichiro',
      post_func: fake_post,
      sleep_func: ->(_) {}
    )

    assert_nil posts[1][:thread_ts]
    assert_includes posts[1][:text], '*koichiro*'
    assert_includes posts[1][:text], 'Investigate failing tests'
    assert_equal posts[1][:ts], posts[2][:thread_ts]
    assert_includes posts[2][:text], '*assistant*'
  end

  def test_process_codex_log_stream_posts_user_and_assistant_messages
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "123.45#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","payload":{"type":"user_message","message":"fix tests"}}',
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"working on it"}}'
                         ].join("\n"))

    exit_code = StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                                         post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 0, exit_code
    assert_equal "*root*\nroot", posts[0][:text]
    assert_nil posts[1][:thread_ts]
    assert_includes posts[1][:text], '*user*'
    assert_includes posts[1][:text], 'fix tests'
    assert_equal posts[1][:ts], posts[2][:thread_ts]
    assert_includes posts[2][:text], '*assistant*'
    assert_includes posts[2][:text], 'working on it'
  end

  def test_process_codex_log_stream_uses_custom_user_name
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"user_message","message":"fix tests"}}')

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             user_name: 'koichiro', post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*koichiro*') })
  end

  def test_process_codex_log_stream_posts_task_complete_message
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}')
    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*assistant*') && post[:text].include?('done') })
  end

  def test_process_codex_log_stream_posts_tool_when_enabled
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"command_execution","command":"ls","stdout":"ok","exit_code":0}}')
    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*tool*') })
    assert(posts.any? { |post| post[:text].include?('```') })
  end

  def test_long_tool_message_is_posted_as_self_contained_block_chunks
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end
    output = 'o' * 7_000
    event = JSON.generate(
      'type' => 'event_msg',
      'payload' => { 'type' => 'command_execution', 'command' => 'run', 'stdout' => output, 'exit_code' => 0 }
    )

    StreamProcessor.process_codex_log_stream(
      StringIO.new(event),
      token: 'xoxb-token',
      channel: 'C123',
      root_message: ROOT_MESSAGE,
      include_tools: true,
      post_func: fake_post,
      sleep_func: ->(_) {}
    )

    chunks = posts.drop(1).map { |post| post.fetch(:text) }
    bodies = chunks.map { |chunk| chunk.split("\n", 2).fetch(1).delete_prefix('```').delete_suffix('```') }
    assert_operator chunks.length, :>, 1
    assert chunks.all? { |chunk| chunk.length <= CodexNotify::MessageFormatter::SLACK_SAFE_LENGTH }
    assert chunks.all? { |chunk| chunk.split("\n", 2).fetch(1).start_with?('```') && chunk.end_with?('```') }
    assert_includes bodies.join, output
  end

  def test_process_codex_log_stream_deduplicates_same_message
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new([
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}',
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}'
                         ].join("\n"))

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             post_func: fake_post, sleep_func: ->(_) {})

    assistant_posts = posts.select { |post| post[:text].include?('*assistant*') }
    assert_equal 1, assistant_posts.length
  end

  def test_process_codex_log_stream_reuses_thread_for_same_session_id
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "200.0#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"first"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply1"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"second"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply2"}}'
                         ].join("\n"))

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             post_func: fake_post, sleep_func: ->(_) {})

    first_user = posts[1]
    first_reply = posts[2]
    second_user = posts[3]
    second_reply = posts[4]

    assert_nil first_user[:thread_ts]
    assert_equal first_user[:ts], first_reply[:thread_ts]
    assert_equal first_user[:ts], second_user[:thread_ts]
    assert_equal first_user[:ts], second_reply[:thread_ts]
  end

  def test_process_codex_log_stream_starts_new_thread_for_different_session_id
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "300.0#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"first"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply1"}}',
                           '{"type":"event_msg","session_id":"session-2","payload":{"type":"user_message","message":"second"}}',
                           '{"type":"event_msg","session_id":"session-2","payload":{"type":"agent_message","message":"reply2"}}'
                         ].join("\n"))

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_message: ROOT_MESSAGE,
                                             post_func: fake_post, sleep_func: ->(_) {})

    first_user = posts[1]
    first_reply = posts[2]
    second_user = posts[3]
    second_reply = posts[4]

    assert_nil first_user[:thread_ts]
    assert_equal first_user[:ts], first_reply[:thread_ts]
    assert_nil second_user[:thread_ts]
    assert_equal second_user[:ts], second_reply[:thread_ts]
  end

  def test_durable_stream_persists_and_orders_roots_and_replies
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      outbox = CodexNotify::SlackOutbox.new(Pathname(dir).join('outbox'))
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))
      publisher = CodexNotify::DurableSlackPublisher.new(client:, store:, outbox:, channel: 'C123')
      events = StringIO.new([
                              '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"prompt"}}',
                              '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply"}}'
                            ].join("\n"))

      code = StreamProcessor.process_codex_log_stream(
        events, token: 'unused', channel: 'C123', root_message: ROOT_MESSAGE,
        post_func: ->(*) {}, publisher:
      )

      assert_equal 0, code
      assert_nil client.posts.fetch(0).last
      assert_nil client.posts.fetch(1).last
      assert_includes client.posts.fetch(1).first, 'prompt'
      assert_equal '1000.01', client.posts.fetch(2).last
      assert_includes client.posts.fetch(2).first, 'reply'
      assert_empty outbox.jobs
    end
  end

end
