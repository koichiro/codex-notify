# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyCLITest < Minitest::Test
  CLI = CodexNotify::CLI

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

    exit_code = CLI.main(['--env-file', 'missing.env'], stderr: err)

    assert_equal 2, exit_code
    assert_includes err.string, 'need --token/--channel'
  end

  def test_main_returns_error_without_session_log
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      err = StringIO.new

      exit_code = CLI.main(['--env-file', 'missing.env', '--sessions-dir', dir.to_s, '--once'], stderr: err)

      assert_equal 2, exit_code
      assert_includes err.string, 'no Codex session log file found'
    end
  end

  def test_main_exits_cleanly_on_interrupt
    with_tmpdir do |dir|
      session_file = dir.join('rollout.jsonl')
      session_file.write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-123\"}}\n")
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      err = StringIO.new

      original = CodexNotify::StreamProcessor.method(:process_codex_log_stream)
      with_silenced_warnings do
        CodexNotify::StreamProcessor.singleton_class.send(:define_method, :process_codex_log_stream) { |*| raise Interrupt }
      end
      begin
        exit_code = CLI.main(['--env-file', 'missing.env', '--session-file', session_file.to_s], stderr: err)
        assert_equal 0, exit_code
      ensure
        with_silenced_warnings do
          CodexNotify::StreamProcessor.singleton_class.send(:define_method, :process_codex_log_stream, original)
        end
      end

      assert_includes err.string, 'Stopped.'
    end
  end

  def test_main_uses_session_meta_payload_id_in_root_post
    with_tmpdir do |dir|
      session_file = dir.join('rollout.jsonl')
      session_file.write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-123\"}}\n")
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'

      posts = []
      original = CLI.method(:slack_post)
      with_silenced_warnings do
        CLI.singleton_class.send(:define_method, :slack_post) do |_token, _channel, text, _thread_ts = nil|
          posts << text
          raise Interrupt
        end
      end
      begin
        CLI.main(['--env-file', 'missing.env', '--session-file', session_file.to_s], stderr: StringIO.new)
      ensure
        with_silenced_warnings do
          CLI.singleton_class.send(:define_method, :slack_post, original)
        end
      end

      assert(posts.any? { |text| text.include?('Session ID: session-123') })
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
