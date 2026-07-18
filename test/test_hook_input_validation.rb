# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyHookInputValidationTest < Minitest::Test
  HookCLI = CodexNotify::HookCLI
  HookInputError = CodexNotify::HookInputError
  HookInputValidator = CodexNotify::HookInputValidator

  def test_invalid_json_is_an_input_error_without_echoing_payload
    with_tmpdir do |dir|
      error = StringIO.new
      exit_code = invoke('{"token":"do-not-print"', dir:, stderr: error)

      assert_equal 2, exit_code
      assert_includes error.string, 'ERROR: hook stdin is not valid JSON'
      refute_includes error.string, 'do-not-print'
      assert_no_hook_side_effects(dir)
    end
  end

  def test_empty_stdin_is_an_input_error
    with_tmpdir do |dir|
      error = StringIO.new
      exit_code = invoke(" \n", dir:, stderr: error)

      assert_equal 2, exit_code
      assert_includes error.string, 'ERROR: hook stdin is empty'
      assert_no_hook_side_effects(dir)
    end
  end

  def test_non_object_json_is_an_input_error
    with_tmpdir do |dir|
      error = StringIO.new
      exit_code = invoke('[]', dir:, stderr: error)

      assert_equal 2, exit_code
      assert_includes error.string, 'hook payload must be a JSON object'
      assert_no_hook_side_effects(dir)
    end
  end

  def test_missing_and_unknown_events_are_input_errors
    with_tmpdir do |dir|
      missing_error = StringIO.new
      unknown_error = StringIO.new

      missing_code = invoke(JSON.generate('session_id' => 'session-1'), dir:, stderr: missing_error)
      unknown_code = invoke(
        JSON.generate('session_id' => 'session-1', 'event' => 'FutureEvent'),
        dir:,
        stderr: unknown_error
      )

      assert_equal 2, missing_code
      assert_includes missing_error.string, 'hook event name is required'
      assert_equal 2, unknown_code
      assert_includes unknown_error.string, 'unsupported hook event'
      refute_includes unknown_error.string, 'FutureEvent'
      assert_no_hook_side_effects(dir)
    end
  end

  def test_argument_and_payload_event_must_match
    with_tmpdir do |dir|
      error = StringIO.new
      payload = {
        'session_id' => 'session-1',
        'hook_event_name' => 'Stop',
        'prompt' => 'hello'
      }

      exit_code = invoke(JSON.generate(payload), dir:, event: 'UserPromptSubmit', stderr: error)

      assert_equal 2, exit_code
      assert_includes error.string, 'hook event names from arguments and payload do not match'
      assert_no_hook_side_effects(dir)
    end
  end

  def test_supported_event_alias_is_normalized
    with_tmpdir do |dir|
      error = StringIO.new
      payload = { 'session_id' => 'session-1', 'source' => 'resume' }

      exit_code = invoke(JSON.generate(payload), dir:, event: 'session_start', stderr: error)

      assert_equal 0, exit_code
      assert_empty error.string
    end
  end

  def test_each_supported_session_id_path_is_accepted
    payloads = [
      { 'session_id' => 'session-1' },
      { 'sessionId' => 'session-1' },
      { 'session' => { 'id' => 'session-1' } }
    ]

    payloads.each do |session_fields|
      event, session_id = HookInputValidator.validate(
        event_name: 'SessionStart',
        payload: session_fields.merge('source' => 'resume')
      )

      assert_equal 'SessionStart', event
      assert_equal 'session-1', session_id
    end
  end

  def test_invalid_session_ids_are_rejected
    invalid_payloads = [
      {},
      { 'session_id' => nil },
      { 'session_id' => '' },
      { 'session_id' => '  ' },
      { 'session_id' => [] },
      { 'session' => 'session-1' }
    ]

    invalid_payloads.each do |session_fields|
      error = assert_raises(HookInputError) do
        HookInputValidator.validate(
          event_name: 'SessionStart',
          payload: session_fields.merge('source' => 'resume')
        )
      end
      assert_match(/session/i, error.message)
    end
  end

  def test_conflicting_session_ids_are_rejected
    error = assert_raises(HookInputError) do
      HookInputValidator.validate(
        event_name: 'SessionStart',
        payload: { 'session_id' => 'one', 'sessionId' => 'two', 'source' => 'resume' }
      )
    end

    assert_includes error.message, 'do not match'
  end

  def test_event_specific_required_fields_are_rejected
    invalid_payloads = {
      'SessionStart' => {},
      'UserPromptSubmit' => {},
      'PreToolUse' => { 'tool_name' => 'Bash' },
      'PostToolUse' => { 'tool_name' => 'Bash' },
      'PermissionRequest' => { 'tool_name' => 'Bash' },
      'Stop' => {}
    }

    invalid_payloads.each do |event_name, fields|
      assert_raises(HookInputError, event_name) do
        HookInputValidator.validate(
          event_name:,
          payload: { 'session_id' => 'session-1' }.merge(fields)
        )
      end
    end
  end

  def test_canonical_event_payloads_are_accepted
    valid_payloads = {
      'SessionStart' => { 'source' => 'future-source' },
      'UserPromptSubmit' => { 'prompt' => 'hello' },
      'PreToolUse' => { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'pwd' } },
      'PostToolUse' => { 'tool_name' => 'Bash', 'tool_response' => { 'exit_code' => 0 } },
      'PermissionRequest' => { 'tool_name' => 'Bash', 'tool_input' => {} },
      'Stop' => { 'last_assistant_message' => '' }
    }

    valid_payloads.each do |event_name, fields|
      event, session_id = HookInputValidator.validate(
        event_name:,
        payload: { 'session_id' => 'session-1', 'extra' => true }.merge(fields)
      )

      assert_equal event_name, event
      assert_equal 'session-1', session_id
    end
  end

  def test_legacy_and_nested_payload_shapes_are_accepted
    valid_payloads = {
      'UserPromptSubmit' => { 'payload' => { 'prompt' => 'hello' } },
      'PreToolUse' => { 'tool_name' => 'Bash', 'command' => 'pwd' },
      'PostToolUse' => { 'tool_name' => 'Bash', 'output' => 'done' },
      'PermissionRequest' => { 'payload' => { 'tool_name' => 'Bash', 'tool_input' => {} } },
      'Stop' => { 'payload' => { 'last_assistant_message' => 'done' } }
    }

    valid_payloads.each do |event_name, fields|
      event, = HookInputValidator.validate(
        event_name:,
        payload: { 'session_id' => 'session-1' }.merge(fields)
      )
      assert_equal event_name, event
    end
  end

  def test_empty_stop_message_is_a_successful_no_op
    with_tmpdir do |dir|
      error = StringIO.new
      payload = { 'session_id' => 'session-1', 'last_assistant_message' => '' }

      exit_code = invoke(JSON.generate(payload), dir:, event: 'Stop', stderr: error)

      assert_equal 0, exit_code
      assert_empty error.string
    end
  end

  def test_runtime_error_uses_exit_code_one
    with_tmpdir do |dir|
      error = StringIO.new
      original_post = CodexNotify::SlackClient.instance_method(:post)
      with_silenced_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |_text, thread_ts: nil|
          raise "Slack failed for #{thread_ts || 'root'}"
        end
      end

      begin
        payload = { 'session_id' => 'session-1', 'prompt' => 'hello' }
        exit_code = invoke(JSON.generate(payload), dir:, event: 'UserPromptSubmit', stderr: error)

        assert_equal 1, exit_code
        assert_includes error.string, 'ERROR: RuntimeError: Slack failed for root'
      ensure
        with_silenced_warnings do
          CodexNotify::SlackClient.send(:define_method, :post, original_post)
        end
      end
    end
  end

  private

  def invoke(raw, dir:, event: nil, stderr: StringIO.new)
    previous_token = ENV['SLACK_BOT_TOKEN']
    ENV['SLACK_BOT_TOKEN'] = 'xoxb-test-token'
    argv = [
      '--env-file', 'missing.env',
      '--channel', 'C123',
      '--state-file', dir.join('state.json').to_s
    ]
    argv.concat(['--event', event]) if event
    HookCLI.main(argv, stdin: StringIO.new(raw), stderr:, stdout: StringIO.new)
  ensure
    previous_token.nil? ? ENV.delete('SLACK_BOT_TOKEN') : ENV['SLACK_BOT_TOKEN'] = previous_token
  end

  def assert_no_hook_side_effects(dir)
    refute dir.join('state.json').exist?
    refute dir.join('state.json.lock').exist?
    refute dir.join('state.json.locks').exist?
  end

  def with_silenced_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end

  def with_tmpdir
    Dir.mktmpdir do |dir|
      yield Pathname(dir)
    end
  end
end
