# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyHookCLITest < Minitest::Test
  HookCLI = CodexNotify::HookCLI
  HookRunner = CodexNotify::HookRunner

  def setup
    @env_backup = ENV.to_h
  end

  def teardown
    ENV.replace(@env_backup)
  end

  def test_main_returns_error_without_credentials
    ENV.delete('SLACK_BOT_TOKEN')
    ENV.delete('SLACK_CHANNEL')

    err = StringIO.new
    exit_code = HookCLI.main(['--env-file', 'missing.env'], stdin: StringIO.new('{}'), stderr: err, stdout: StringIO.new)

    assert_equal 2, exit_code
    assert_includes err.string, 'need --token/--channel'
  end

  def test_user_prompt_submit_reuses_same_thread_for_same_session
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'prompt' => 'hello' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        2.times do
          HookCLI.main(
            ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
            stdin: StringIO.new(JSON.generate(payload)),
            stderr: StringIO.new,
            stdout: StringIO.new
          )
        end
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      root_posts = posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = posts.select { |(_text, thread_ts)| !thread_ts.nil? }

      assert_equal 1, root_posts.size
      assert_equal 1, reply_posts.size
      assert_equal '1000.01', reply_posts.first.last
      assert_includes root_posts.first.first, 'hello'
    end
  end

  def test_stop_posts_last_assistant_message_in_existing_thread
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      prompt_payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'prompt' => 'hello' }
      stop_payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'last_assistant_message' => 'done' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(prompt_payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )

        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'Stop'],
          stdin: StringIO.new(JSON.generate(stop_payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      assert_equal 2, posts.size
      assert_includes posts.last.first, 'done'
      assert_equal '1000.01', posts.last.last
    end
  end

  def test_session_start_does_not_post_root_message
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'SessionStart'],
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      assert_empty posts
    end
  end

  def test_reset_marker_clears_thread_without_posting
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      session_payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          ts = thread_ts || (posts.count { |(_t, ts_value)| ts_value.nil? } == 1 ? '1000.01' : '2000.01')
          { 'ok' => true, 'ts' => ts }
        end
      end

      begin
        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(session_payload.merge('prompt' => 'first prompt'))),
          stderr: StringIO.new,
          stdout: StringIO.new
        )

        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(session_payload.merge('prompt' => '---'))),
          stderr: StringIO.new,
          stdout: StringIO.new
        )

        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(session_payload.merge('prompt' => 'second prompt'))),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      root_posts = posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = posts.select { |(_text, thread_ts)| !thread_ts.nil? }

      assert_equal 2, root_posts.size
      assert_equal 0, reply_posts.size
      assert_includes root_posts[0].first, 'first prompt'
      assert_includes root_posts[1].first, 'second prompt'
      refute posts.any? { |(text, _thread_ts)| text.include?('---') }
    end
  end

  def test_user_prompt_submit_recovers_when_saved_thread_ts_is_stale
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => 'stale-ts' } }))
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'prompt' => 'recovered prompt' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          if thread_ts == 'stale-ts'
            raise CodexNotify::SlackClient::Error.new('Slack API error', error_code: 'thread_not_found')
          end

          { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
        end
      end

      begin
        exit_code = HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )

        assert_equal 0, exit_code
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      root_posts = posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = posts.select { |(_text, thread_ts)| !thread_ts.nil? }

      assert_equal 1, root_posts.size
      assert_equal 2, reply_posts.size
      assert_equal 'stale-ts', reply_posts.first.last
      assert_equal '2000.01', reply_posts.last.last
      assert_includes root_posts.first.first, 'recovered prompt'
      assert_equal '2000.01', JSON.parse(state_file.read).dig('threads', 'session-123')
    end
  end

  def test_stop_recovers_when_saved_thread_ts_is_stale
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => 'stale-ts' } }))
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'last_assistant_message' => 'done' }

      posts = []
      original_new = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          if thread_ts == 'stale-ts'
            raise CodexNotify::SlackClient::Error.new('Slack API error', error_code: 'thread_not_found')
          end

          { 'ok' => true, 'ts' => (thread_ts || '3000.01') }
        end
      end

      begin
        exit_code = HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'Stop'],
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )

        assert_equal 0, exit_code
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      root_posts = posts.select { |(_text, thread_ts)| thread_ts.nil? }
      reply_posts = posts.select { |(_text, thread_ts)| !thread_ts.nil? }

      assert_equal 1, root_posts.size
      assert_equal 2, reply_posts.size
      assert_equal 'stale-ts', reply_posts.first.last
      assert_equal '3000.01', reply_posts.last.last
      assert_includes root_posts.first.first, 'Codex hook notification started.'
      assert_includes reply_posts.last.first, 'done'
      assert_equal '3000.01', JSON.parse(state_file.read).dig('threads', 'session-123')
    end
  end

  private

  def with_tmpdir
    Dir.mktmpdir do |dir|
      yield Pathname(dir)
    end
  end

  def with_silenced_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end
end
