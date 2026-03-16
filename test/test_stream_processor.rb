# frozen_string_literal: true

require 'stringio'
require_relative 'test_helper'

class CodexNotifyStreamProcessorTest < Minitest::Test
  StreamProcessor = CodexNotify::StreamProcessor

  def test_process_events_posts_root_assistant_and_finish
    posts = []
    fake_post = lambda do |token, channel, text, thread_ts = nil|
      posts << { token:, channel:, text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new([
                           '{"type":"turn.started"}',
                           '{"type":"item.completed","item":{"type":"assistant_message","text":"hello"}}'
                         ].join("\n"))

    exit_code = StreamProcessor.process_events(
      events,
      token: 'xoxb-token',
      channel: 'C123',
      root_text: 'root',
      initial_prompt: 'fix failing test',
      post_func: fake_post,
      sleep_func: ->(_) {}
    )

    assert_equal 0, exit_code
    assert_equal 'root', posts[0][:text]
    assert_equal '123.456', posts[1][:thread_ts]
    assert_includes posts[1][:text], '*user*'
    assert_includes posts[1][:text], 'fix failing test'
    assert_includes posts[2][:text], '*assistant*'
    assert_includes posts[2][:text], 'hello'
    assert_includes posts[3][:text], 'Codex run finished'
  end

  def test_process_events_does_not_post_turn_started
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    StreamProcessor.process_events(StringIO.new('{"type":"turn.started"}'),
                                   token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_equal 'root', posts[0]
    assert_includes posts[1], 'Codex run finished'
  end

  def test_process_events_skips_invalid_json
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    StreamProcessor.process_events(StringIO.new("not-json\n\n"),
                                   token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_equal 'root', posts[0]
    assert_includes posts[1], 'Codex run finished'
  end

  def test_process_events_includes_tools_when_enabled
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0,"stdout":"ok","stderr":""}}')
    StreamProcessor.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('command_execution') })
    assert(posts.any? { |post| post.include?("COMMAND:\nls") })
  end

  def test_process_events_ignores_tools_when_disabled
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0}}')
    StreamProcessor.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   include_tools: false, post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_includes posts[-1], 'Codex run finished'
  end

  def test_process_events_handles_user_message
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"turn.started"}' + "\n" + '{"type":"item.completed","item":{"type":"user_message","text":"please fix it"}}')
    StreamProcessor.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('*user*') })
    assert(posts.any? { |post| post.include?('please fix it') })
  end

  def test_process_events_posts_concise_failure
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    StreamProcessor.process_events(StringIO.new("{\"type\":\"turn.started\"}\n{\"type\":\"turn.failed\"}"),
                                   token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                   post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('*system*') })
    assert(posts.any? { |post| post.include?('turn 1 failed') })
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

    exit_code = StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                                         post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 0, exit_code
    assert_equal 'root', posts[0][:text]
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

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
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
    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
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
    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                             include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*tool*') })
    assert(posts.any? { |post| post[:text].include?('```') })
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

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
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

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
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

    StreamProcessor.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
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

  def test_process_events_posts_other_tool_types
    %w[file_change web_search something_else].each do |item_type|
      posts = []
      fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
        posts << text
        { 'ok' => true, 'ts' => '123.456' }
      end

      payload = "{\"type\":\"item.completed\",\"item\":{\"type\":\"#{item_type}\",\"value\":\"x\"}}"
      StreamProcessor.process_events(StringIO.new(payload), token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                     include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

      assert_operator posts.length, :>=, 2
    end
  end
end
