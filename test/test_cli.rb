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
      session_file.write('')
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      err = StringIO.new

      original = CLI.method(:process_codex_log_stream)
      with_silenced_warnings do
        CLI.singleton_class.send(:define_method, :process_codex_log_stream) { |*| raise Interrupt }
      end
      begin
        exit_code = CLI.main(['--env-file', 'missing.env', '--session-file', session_file.to_s], stderr: err)
        assert_equal 0, exit_code
      ensure
        with_silenced_warnings do
          CLI.singleton_class.send(:define_method, :process_codex_log_stream, original)
        end
      end

      assert_includes err.string, 'Stopped.'
    end
  end


  def test_extract_events_reads_message_parts
    obj = {
      'type' => 'response_item',
      'payload' => {
        'type' => 'message',
        'role' => 'assistant',
        'content' => [
          { 'type' => 'output_text', 'text' => 'part one' },
          { 'type' => 'output_text', 'text' => 'part two' }
        ]
      }
    }

    events = CLI.extract_events(obj)
    assert_includes events, ['assistant', 'part one', 'output_text']
    assert_includes events, ['assistant', 'part two', 'output_text']
  end

  def test_extract_events_reads_payload_input_text
    obj = { 'type' => 'x', 'payload' => { 'type' => 'input_text', 'text' => 'hello' } }
    assert_includes CLI.extract_events(obj), ['user', 'hello', 'input_text']
  end

  def test_extract_events_reads_direct_output_text
    obj = { 'type' => 'output_text', 'text' => 'done' }
    assert_includes CLI.extract_events(obj), ['assistant', 'done', 'output_text']
  end

  def test_extract_events_reads_nested_user_message
    obj = {
      'type' => 'wrapper',
      'message' => {
        'type' => 'event_msg',
        'payload' => { 'type' => 'user_message', 'message' => 'hello' }
      }
    }

    assert_includes CLI.extract_events(obj), ['user', 'hello', 'input_text']
  end

  def test_extract_events_reads_tool_from_nested_payload
    obj = {
      'type' => 'wrapper',
      'payload' => {
        'type' => 'something',
        'tool_result' => { 'type' => 'tool_result', 'name' => 'x', 'output' => { 'ok' => true } }
      }
    }

    assert(CLI.extract_events(obj).any? { |event| event[0] == 'tool' })
  end

  def test_extract_session_id_reads_nested_session_id
    obj = {
      'type' => 'event_msg',
      'payload' => {
        'type' => 'user_message',
        'message' => 'hello',
        'session_id' => 'sess-1'
      }
    }

    assert_equal 'sess-1', CLI.extract_session_id(obj)
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
