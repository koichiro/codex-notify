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
      assert_equal 2, reply_posts.size
      assert reply_posts.all? { |(_text, thread_ts)| thread_ts == '1000.01' }
    end
  end

  def test_stop_posts_last_assistant_message
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      state_file = dir.join('state.json')
      payload = {
        'session_id' => 'session-123',
        'cwd' => '/tmp/app',
        'last_assistant_message' => 'done'
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
          stdin: StringIO.new(JSON.generate(payload)),
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
