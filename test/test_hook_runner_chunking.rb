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
        expected = CodexNotify::HookFormatter.prompt_text(user_name: 'Codex', prompt:)

        assert_equal 0, runner.run(
          event_name: 'UserPromptSubmit',
          payload: { 'session_id' => 'session-1', 'prompt' => prompt }
        )

        assert_equal CodexNotify::MessageFormatter.chunk_text(expected).to_a, posts.map(&:first)
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
        cases = [
          [
            'UserPromptSubmit',
            { 'session_id' => 'session-1', 'prompt' => 'u' * 4_000 },
            CodexNotify::HookFormatter.prompt_text(user_name: 'Codex', prompt: 'u' * 4_000)
          ],
          [
            'PreToolUse',
            { 'session_id' => 'session-1', 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'c' * 4_000 } },
            CodexNotify::HookFormatter.format_pre_tool('tool_input' => { 'command' => 'c' * 4_000 })
          ],
          [
            'PostToolUse',
            { 'session_id' => 'session-1', 'tool_name' => 'Bash', 'tool_response' => { 'stdout' => 'o' * 4_000 } },
            CodexNotify::HookFormatter.format_post_tool('tool_response' => { 'stdout' => 'o' * 4_000 })
          ],
          [
            'PermissionRequest',
            { 'session_id' => 'session-1', 'tool_name' => 'Bash', 'tool_input' => { 'description' => 'p' * 4_000 } },
            CodexNotify::HookFormatter.format_permission_request(
              'tool_name' => 'Bash', 'tool_input' => { 'description' => 'p' * 4_000 }
            )
          ],
          [
            'Stop',
            { 'session_id' => 'session-1', 'last_assistant_message' => 'a' * 4_000 },
            CodexNotify::HookFormatter.assistant_text('a' * 4_000)
          ]
        ]

        cases.each do |event_name, payload, expected|
          start = posts.length
          assert_equal 0, runner.run(event_name:, payload:), event_name
          event_posts = posts.drop(start)

          assert_equal CodexNotify::MessageFormatter.chunk_text(expected).to_a,
                       event_posts.map(&:first), event_name
          assert event_posts.all? { |(_text, thread_ts)| thread_ts == '1000.01' }, event_name
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
      expected = CodexNotify::HookFormatter.prompt_text(user_name: 'Codex', prompt:)

      stub = lambda do |text, thread_ts|
        attempts << [text, thread_ts]
        if thread_ts == 'stale-ts'
          raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'thread_not_found')
        end

        { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
      end
      with_stubbed_post(stub) do
        runner = build_runner(state_file)
        assert_equal 0, runner.run(
          event_name: 'UserPromptSubmit',
          payload: { 'session_id' => 'session-1', 'prompt' => prompt }
        )
      end

      successful_posts = attempts.reject { |(_text, thread_ts)| thread_ts == 'stale-ts' }
      assert_equal CodexNotify::MessageFormatter.chunk_text(expected).to_a, successful_posts.map(&:first)
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
      expected = CodexNotify::HookFormatter.assistant_text(message)

      stub = lambda do |text, thread_ts|
        attempts << [text, thread_ts]
        if thread_ts == 'stale-ts'
          raise CodexNotify::SlackClient::Error.new('stale thread', error_code: 'thread_not_found')
        end

        { 'ok' => true, 'ts' => (thread_ts || '3000.01') }
      end
      with_stubbed_post(stub) do
        runner = build_runner(state_file)
        assert_equal 0, runner.run(
          event_name: 'Stop',
          payload: { 'session_id' => 'session-1', 'last_assistant_message' => message }
        )
      end

      successful_posts = attempts.reject { |(_text, thread_ts)| thread_ts == 'stale-ts' }
      root_posts = successful_posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = successful_posts.select { |(_text, thread_ts)| thread_ts == '3000.01' }

      assert_equal 1, root_posts.length
      assert_includes root_posts.first.first, 'Codex hook notification started.'
      assert_equal CodexNotify::MessageFormatter.chunk_text(expected).to_a, reply_posts.map(&:first)
    end
  end

  private

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
