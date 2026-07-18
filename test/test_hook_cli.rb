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

  def test_parse_stdin_accepts_a_json_object_at_the_byte_limit
    empty_payload = JSON.generate('padding' => '')
    padding = 'a' * (HookCLI::MAX_STDIN_BYTES - empty_payload.bytesize)
    raw = JSON.generate('padding' => padding)

    assert_equal HookCLI::MAX_STDIN_BYTES, raw.bytesize
    assert_equal padding, HookCLI.parse_stdin(StringIO.new(raw)).fetch('padding')
  end

  def test_parse_stdin_rejects_input_over_the_byte_limit
    raw = 'x' * (HookCLI::MAX_STDIN_BYTES + 1)

    error = assert_raises(CodexNotify::HookInputError) do
      HookCLI.parse_stdin(StringIO.new(raw))
    end

    assert_includes error.message, HookCLI::MAX_STDIN_BYTES.to_s
  end

  def test_parse_stdin_limit_counts_multibyte_content_in_bytes
    raw = JSON.generate('padding' => 'あ' * (HookCLI::MAX_STDIN_BYTES / 3))
    assert_operator raw.length, :<, HookCLI::MAX_STDIN_BYTES
    assert_operator raw.bytesize, :>, HookCLI::MAX_STDIN_BYTES

    error = assert_raises(CodexNotify::HookInputError) do
      HookCLI.parse_stdin(StringIO.new(raw))
    end

    assert_includes error.message, 'maximum size'
  end

  def test_oversized_stdin_does_not_post_or_update_state
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      state_file = dir.join('state.json')
      posts = []
      original_post = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => '1000.01' }
        end
      end

      begin
        error = StringIO.new
        exit_code = HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new('x' * (HookCLI::MAX_STDIN_BYTES + 1)),
          stderr: error,
          stdout: StringIO.new
        )

        assert_equal 2, exit_code
        assert_includes error.string, 'maximum size'
        assert_empty posts
        refute state_file.exist?
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_post)
        end
      end
    end
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

  def test_normal_mode_suppresses_internal_overview_prompt
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'prompt' => internal_overview_prompt('/tmp/app')
      }

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
          ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--event', 'UserPromptSubmit'],
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

  def test_debug_mode_keeps_internal_overview_prompt_visible
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'prompt' => internal_overview_prompt('/tmp/app')
      }

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
          ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--mode', 'debug', '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      assert_equal 1, posts.size
      assert_includes posts.first.first, '# Overview'
    end
  end

  def test_normal_mode_suppresses_internal_ambient_policy_prompt
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'prompt' => internal_ambient_policy_prompt
      }

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
      assert JSON.parse(state_file.read).dig('suppressed_sessions', 'session-123')
    end
  end

  def test_normal_mode_clears_existing_thread_when_internal_ambient_policy_prompt_is_suppressed
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => '1000.01' } }))
      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'prompt' => internal_ambient_policy_prompt
      }

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
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      state = JSON.parse(state_file.read)
      assert_empty posts
      assert_nil state.dig('threads', 'session-123')
      assert state.dig('suppressed_sessions', 'session-123')
    end
  end

  def test_debug_mode_keeps_internal_ambient_policy_prompt_visible
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'prompt' => internal_ambient_policy_prompt
      }

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
          ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--mode', 'debug', '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate(payload)),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_new)
        end
      end

      assert_equal 1, posts.size
      assert_includes posts.first.first, 'safety and compliance standards'
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

  def test_stop_skips_suppressed_internal_ambient_session
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({
                                       'threads' => { 'session-123' => '1000.01' },
                                       'suppressed_sessions' => {
                                         'session-123' => { 'reason' => 'internal_ambient_suggestions' }
                                       }
                                     }))
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

      assert_empty posts
    end
  end

  def test_stop_skips_internal_ambient_response_signature_in_existing_thread
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => '1000.01' } }))
      stop_payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'last_assistant_message' => internal_ambient_policy_response
      }

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

      assert_empty posts
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

  def test_session_start_with_startup_source_clears_saved_thread
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => '1000.01' } }))
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'source' => 'startup' }

      HookCLI.main(
        ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'SessionStart'],
        stdin: StringIO.new(JSON.generate(payload)),
        stderr: StringIO.new,
        stdout: StringIO.new
      )

      assert_nil JSON.parse(state_file.read).dig('threads', 'session-123')
    end
  end

  def test_session_start_with_clear_source_clears_saved_thread
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => '1000.01' } }))
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'source' => 'clear' }

      HookCLI.main(
        ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'SessionStart'],
        stdin: StringIO.new(JSON.generate(payload)),
        stderr: StringIO.new,
        stdout: StringIO.new
      )

      assert_nil JSON.parse(state_file.read).dig('threads', 'session-123')
    end
  end

  def test_session_start_with_resume_source_keeps_saved_thread
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      state_file.write(JSON.generate({ 'threads' => { 'session-123' => '1000.01' } }))
      payload = { 'session_id' => 'session-123', 'cwd' => '/tmp/app', 'source' => 'resume' }

      HookCLI.main(
        ['--env-file', 'missing.env', '--state-file', state_file.to_s, '--event', 'SessionStart'],
        stdin: StringIO.new(JSON.generate(payload)),
        stderr: StringIO.new,
        stdout: StringIO.new
      )

      assert_equal '1000.01', JSON.parse(state_file.read).dig('threads', 'session-123')
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
      assert_equal 1, reply_posts.size
      assert_equal 'stale-ts', reply_posts.first.last
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

  def test_normal_mode_does_not_post_session_or_tool_events
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      posts = []
      original_post = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        {
          'SessionStart' => { 'source' => 'startup' },
          'PreToolUse' => { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'pwd' } },
          'PostToolUse' => { 'tool_name' => 'Bash', 'tool_response' => { 'output' => '/tmp' } }
        }.each do |event_name, extra_payload|
          HookCLI.main(
            ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--event', event_name],
            stdin: StringIO.new(JSON.generate({ 'session_id' => 'session-123', 'cwd' => '/tmp/app' }.merge(extra_payload))),
            stderr: StringIO.new,
            stdout: StringIO.new
          )
        end
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_post)
        end
      end

      assert_empty posts
    end
  end

  def test_debug_mode_posts_session_and_tool_events
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      posts = []
      original_post = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        {
          'SessionStart' => { 'source' => 'startup' },
          'PreToolUse' => { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'pwd' } },
          'PostToolUse' => { 'tool_name' => 'Bash', 'tool_response' => { 'output' => '/tmp' } }
        }.each do |event_name, extra_payload|
          HookCLI.main(
            ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--mode', 'debug', '--event', event_name],
            stdin: StringIO.new(JSON.generate({ 'session_id' => 'session-123', 'cwd' => '/tmp/app' }.merge(extra_payload))),
            stderr: StringIO.new,
            stdout: StringIO.new
          )
        end
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_post)
        end
      end

      assert_equal 3, posts.size
      assert_nil posts.first.last
      assert_includes posts.first.first, 'Codex hook notification started.'
      assert posts.drop(1).all? { |(_text, thread_ts)| thread_ts == '1000.01' }
      assert posts.any? { |(text, _thread_ts)| text.include?('$ pwd') }
      assert posts.any? { |(text, _thread_ts)| text.include?('/tmp') }
    end
  end

  def test_permission_request_posts_in_normal_mode
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      posts = []
      original_post = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          posts << [text, thread_ts]
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      begin
        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--event', 'UserPromptSubmit'],
          stdin: StringIO.new(JSON.generate('session_id' => 'session-123', 'cwd' => '/tmp/app', 'prompt' => 'run tests')),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
        HookCLI.main(
          ['--env-file', 'missing.env', '--state-file', dir.join('state.json').to_s, '--event', 'PermissionRequest'],
          stdin: StringIO.new(JSON.generate(
            'session_id' => 'session-123',
            'cwd' => '/tmp/app',
            'tool_name' => 'Bash',
            'tool_input' => { 'description' => 'Allow network access?' }
          )),
          stderr: StringIO.new,
          stdout: StringIO.new
        )
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_post)
        end
      end

      assert_equal 2, posts.size
      assert_includes posts.last.first, 'approval required: Bash'
      assert_includes posts.last.first, 'Allow network access?'
      assert_equal '1000.01', posts.last.last
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

  def internal_overview_prompt(project_path)
    <<~PROMPT
      # Overview

      Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: #{project_path}

      Get an understanding of the user's intent and goals by deeply viewing their connected apps. Suggest actionable tasks that they would actually act on/click.
      Infer what the user works on and their style from their connected apps.
      Optimize for relief: choose suggestions that make the user's life easier, reduce an open loop, unblock work, or prepare them for something that is about to matter.
    PROMPT
  end

  def internal_ambient_policy_prompt
    <<~PROMPT
      You are an expert at upholding safety and compliance standards for Codex ambient suggestions.

      I will present you with two categories of content: things to **ALWAYS** exclude, and things which you should exclude if they are about the user (**unless** the recent user context shows the user has specifically asked for it).

      Then, I will show you a list of ambient suggestion candidates.

      Your task is to determine if any suggestions should be excluded in order to adhere to the safety and compliance policies.

      ## 1. Policies to always exclude

      ### A - Abuse (non-hate)
      - Scope: Content including abuse toward non-protected targets; if target is a protected class, use H instead.
    PROMPT
  end

  def internal_ambient_policy_response
    <<~RESPONSE
      - `exclude`: a list of objects describing suggestions to exclude. Each object must have:
        - `id`: the suggestion_id to exclude
        - `reason`: a short sentence explaining why the suggestion should be excluded, referencing the applicable policy

      You must not output any other text. Only output the JSON object.
    RESPONSE
  end
end
