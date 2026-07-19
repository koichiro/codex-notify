# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'
require_relative 'support/fake_slack_client'

class CodexNotifyHookInputValidationTest < Minitest::Test
  include HookTestSupport

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
      event = HookInputValidator.validate(
        event_name: 'SessionStart',
        payload: session_fields.merge('source' => 'resume')
      )

      assert_instance_of CodexNotify::HookEvent, event
      assert_equal 'SessionStart', event.name
      assert_equal 'session-1', event.session_id
      assert event.frozen?
      assert event.name.frozen?
      assert event.session_id.frozen?
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
      event = HookInputValidator.validate(
        event_name:,
        payload: { 'session_id' => 'session-1', 'extra' => true }.merge(fields)
      )

      assert_equal event_name, event.name
      assert_equal 'session-1', event.session_id
      assert_nil event.raw_payload
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
      event = HookInputValidator.validate(
        event_name:,
        payload: { 'session_id' => 'session-1' }.merge(fields)
      )
      assert_equal event_name, event.name
    end
  end

  def test_current_legacy_and_nested_shapes_produce_the_same_canonical_event
    pairs = [
      ['SessionStart', { 'source' => 'resume' }, { 'payload' => { 'source' => 'resume' } }],
      ['UserPromptSubmit', { 'prompt' => 'hello' }, { 'payload' => { 'prompt' => 'hello' } }],
      [
        'PreToolUse',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'pwd' } },
        { 'payload' => { 'tool_name' => 'Bash', 'command' => 'pwd' } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'stdout' => 'done', 'exitCode' => 0 } },
        { 'payload' => { 'tool_name' => 'Bash', 'output' => 'done', 'exit_code' => 0 } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } },
        { 'payload' => { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } },
        { 'tool_name' => 'Bash', 'tool_output' => 'done' }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'stderr' => 'failed' } },
        { 'tool_name' => 'Bash', 'stderr' => 'failed' }
      ],
      [
        'PermissionRequest',
        { 'tool_name' => 'Bash', 'tool_input' => { 'description' => 'Allow?' } },
        { 'payload' => { 'tool_name' => 'Bash', 'tool_input' => { 'description' => 'Allow?' } } }
      ],
      [
        'Stop',
        { 'last_assistant_message' => 'done' },
        { 'payload' => { 'last_assistant_message' => 'done' } }
      ]
    ]

    pairs.each do |event_name, current, compatible|
      current_event = canonical_event(event_name, current)
      compatible_event = canonical_event(event_name, compatible)

      assert_equal current_event, compatible_event, event_name
    end
  end

  def test_top_level_event_fields_take_precedence_over_nested_fields
    event = canonical_event(
      'UserPromptSubmit',
      'prompt' => 'top-level',
      'payload' => { 'prompt' => 'nested' }
    )

    assert_equal 'top-level', event.prompt
  end

  def test_invalid_explicit_tool_response_is_not_masked_by_legacy_output
    error = assert_raises(HookInputError) do
      canonical_event(
        'PostToolUse',
        'tool_name' => 'Bash',
        'tool_response' => 123,
        'output' => 'legacy output'
      )
    end

    assert_includes error.message, 'tool_response must be an object or string'
  end

  def test_raw_payload_is_retained_only_for_debug_formatting_fallbacks
    pre_payload = {
      'session_id' => 'session-1',
      'tool_name' => 'Bash',
      'tool_input' => { 'path' => '/tmp' }
    }
    post_payload = {
      'session_id' => 'session-1',
      'tool_name' => 'Bash',
      'tool_response' => { 'metadata' => true }
    }

    pre_event = HookInputValidator.validate(event_name: 'PreToolUse', payload: pre_payload)
    post_event = HookInputValidator.validate(event_name: 'PostToolUse', payload: post_payload)
    prompt_event = canonical_event('UserPromptSubmit', 'prompt' => 'hello')

    assert_equal pre_payload, pre_event.raw_payload
    assert_equal post_payload, post_event.raw_payload
    assert pre_event.raw_payload.frozen?
    assert pre_event.raw_payload['tool_input'].frozen?
    assert_nil prompt_event.raw_payload
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
      client = FakeSlackClient.new do |_text, thread_ts|
        raise "Slack failed for #{thread_ts || 'root'}"
      end

      payload = { 'session_id' => 'session-1', 'prompt' => 'hello' }
      exit_code = invoke(JSON.generate(payload), dir:, event: 'UserPromptSubmit', stderr: error, client:)

      assert_equal 1, exit_code
      assert_includes error.string, 'ERROR: RuntimeError: Slack failed for root'
    end
  end

  private

  def canonical_event(event_name, fields)
    HookInputValidator.validate(
      event_name:,
      payload: { 'session_id' => 'session-1' }.merge(fields)
    )
  end

  def invoke(raw, dir:, event: nil, stderr: StringIO.new, client: FakeSlackClient.new)
    previous_token = ENV['SLACK_BOT_TOKEN']
    ENV['SLACK_BOT_TOKEN'] = 'xoxb-test-token'
    argv = [
      '--env-file', 'missing.env',
      '--channel', 'C123',
      '--state-file', dir.join('state.json').to_s
    ]
    argv.concat(['--event', event]) if event
    HookCLI.main(
      argv,
      stdin: StringIO.new(raw),
      stderr:,
      stdout: StringIO.new,
      runner_factory: hook_runner_factory(client:)
    )
  ensure
    previous_token.nil? ? ENV.delete('SLACK_BOT_TOKEN') : ENV['SLACK_BOT_TOKEN'] = previous_token
  end

  def assert_no_hook_side_effects(dir)
    refute dir.join('state.json').exist?
    refute dir.join('state.json.lock').exist?
    refute dir.join('state.json.locks').exist?
  end

  def with_tmpdir
    Dir.mktmpdir do |dir|
      yield Pathname(dir)
    end
  end
end
