# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'test_helper'

class HookRunnerChunkingTest < Minitest::Test
  def test_long_first_prompt_uses_first_chunk_as_root_and_replies_with_the_rest
    with_tmpdir do |dir|
      with_captured_posts do |posts|
        runner = build_runner(dir.join('state.json'))
        prompt = 'a' * 7_000
        event = hook_event('UserPromptSubmit', 'prompt' => prompt)
        message = CodexNotify::HookFormatter.prompt_message(event, user_name: 'Codex')

        assert_equal 0, runner.run(event:)

        assert_message_posts(posts, message)
        assert_nil posts.first.last
        assert posts.drop(1).all? { |(_text, thread_ts)| thread_ts == '1000.01' }
        assert posts.all? { |(text, _thread_ts)| text.length <= 3_500 }
      end
    end
  end

  def test_all_hook_message_types_are_chunked_in_an_existing_thread
    with_tmpdir do |dir|
      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-1' => '1000.01' } }))

      with_captured_posts do |posts|
        runner = build_runner(state_file, mode: 'debug')
        events = [
          hook_event('UserPromptSubmit', 'prompt' => 'u' * 4_000),
          hook_event('PreToolUse', 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'c' * 4_000 }),
          hook_event('PostToolUse', 'tool_name' => 'Bash', 'tool_response' => { 'stdout' => 'o' * 4_000 }),
          hook_event(
            'PermissionRequest',
            'tool_name' => 'Bash',
            'tool_input' => { 'description' => 'p' * 4_000 }
          ),
          hook_event('Stop', 'last_assistant_message' => 'a' * 4_000)
        ]

        events.each do |event|
          message = message_for(event)
          start = posts.length
          assert_equal 0, runner.run(event:), event.name
          event_posts = posts.drop(start)

          assert_message_posts(event_posts, message)
          assert event_posts.all? { |(_text, thread_ts)| thread_ts == '1000.01' }, event.name
        end
      end
    end
  end

  def test_stale_thread_recovery_does_not_duplicate_a_long_prompt
    with_tmpdir do |dir|
      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-1' => 'stale-ts' } }))
      attempts = []
      prompt = 'a' * 7_000
      event = hook_event('UserPromptSubmit', 'prompt' => prompt)
      message = CodexNotify::HookFormatter.prompt_message(event, user_name: 'Codex')

      stub = lambda do |text, thread_ts|
        attempts << [text, thread_ts]
        if thread_ts == 'stale-ts'
          raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'thread_not_found')
        end

        { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
      end
      with_stubbed_post(stub) do
        runner = build_runner(state_file)
        assert_equal 0, runner.run(event:)
      end

      successful_posts = attempts.reject { |(_text, thread_ts)| thread_ts == 'stale-ts' }
      assert_message_posts(successful_posts, message)
      assert_nil successful_posts.first.last
      assert successful_posts.drop(1).all? { |(_text, thread_ts)| thread_ts == '2000.01' }
      assert_equal '2000.01', JSON.parse(state_file.read).dig('threads', 'session-1')
    end
  end

  def test_stale_thread_recovery_posts_long_stop_after_new_session_root
    with_tmpdir do |dir|
      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-1' => 'stale-ts' } }))
      attempts = []
      message = 'a' * 7_000
      event = hook_event('Stop', 'last_assistant_message' => message)
      formatted_message = CodexNotify::HookFormatter.assistant_message(event)

      stub = lambda do |text, thread_ts|
        attempts << [text, thread_ts]
        if thread_ts == 'stale-ts'
          raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'thread_not_found')
        end

        { 'ok' => true, 'ts' => (thread_ts || '3000.01') }
      end
      with_stubbed_post(stub) do
        runner = build_runner(state_file)
        assert_equal 0, runner.run(event:)
      end

      successful_posts = attempts.reject { |(_text, thread_ts)| thread_ts == 'stale-ts' }
      root_posts = successful_posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = successful_posts.select { |(_text, thread_ts)| thread_ts == '3000.01' }

      assert_equal 1, root_posts.length
      assert_includes root_posts.first.first, 'Codex hook notification started.'
      assert_message_posts(reply_posts, formatted_message)
    end
  end

  private

  def hook_event(event_name, fields)
    CodexNotify::HookInputValidator.validate(
      event_name:,
      payload: { 'session_id' => 'session-1' }.merge(fields)
    )
  end

  def message_for(event)
    case event.name
    when 'UserPromptSubmit' then CodexNotify::HookFormatter.prompt_message(event, user_name: 'Codex')
    when 'PreToolUse' then CodexNotify::HookFormatter.pre_tool_message(event)
    when 'PostToolUse' then CodexNotify::HookFormatter.post_tool_message(event)
    when 'PermissionRequest' then CodexNotify::HookFormatter.permission_request_message(event)
    when 'Stop' then CodexNotify::HookFormatter.assistant_message(event)
    end
  end

  def assert_message_posts(posts, message)
    texts = posts.map(&:first)
    assert_operator texts.length, :>, 1
    assert texts.all? { |text| text.length <= CodexNotify::MessageFormatter::SLACK_SAFE_LENGTH }
    assert_equal message.body, reconstructed_body(texts, message.presentation)
    assert_equal "*#{message.title}*", texts.first.lines.first.chomp
    assert_includes texts[1].lines.first, '(cont.)'
    return unless message.presentation == :block

    assert texts.all? { |text| text.split("\n", 2).last.start_with?('```') }
    assert texts.all? { |text| text.end_with?('```') }
  end

  def reconstructed_body(texts, presentation)
    texts.map do |text|
      body = text.split("\n", 2).fetch(1)
      presentation == :block ? body.delete_prefix('```').delete_suffix('```') : body
    end.join
  end

  def build_runner(state_file, mode: 'normal')
    CodexNotify::HookRunner.new(
      token: 'token',
      channel: 'channel',
      user_name: 'Codex',
      title: nil,
      state_file:,
      mode:
    )
  end

  def with_captured_posts
    posts = []
    stub = lambda do |text, thread_ts|
      posts << [text, thread_ts]
      { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
    end
    with_stubbed_post(stub) { yield posts }
  end

  def with_stubbed_post(stub)
    original_post = CodexNotify::SlackClient.instance_method(:post)
    without_warnings do
      CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
        stub.call(text, thread_ts)
      end
    end
    yield
  ensure
    without_warnings { CodexNotify::SlackClient.send(:define_method, :post, original_post) } if original_post
  end

  def without_warnings
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  def with_tmpdir
    Dir.mktmpdir { |dir| yield Pathname(dir) }
  end
end
