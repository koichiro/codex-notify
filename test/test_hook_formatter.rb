# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyHookFormatterTest < Minitest::Test
  HookFormatter = CodexNotify::HookFormatter

  def test_formats_current_pre_tool_use_payload
    text = render(HookFormatter.pre_tool_message(
      hook_event('PreToolUse', 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'bundle exec rake' })
    ))

    assert_includes text, '$ bundle exec rake'
    refute_includes text, '"command"'
  end

  def test_formats_current_post_tool_use_payload
    text = render(HookFormatter.post_tool_message(
      hook_event('PostToolUse', 'tool_name' => 'Bash', 'tool_response' => {
        'exit_code' => 1,
        'stdout' => 'test output',
        'stderr' => 'test failure'
      })
    ))

    assert_includes text, '[exit_code] 1'
    assert_includes text, "[output]\ntest output"
    assert_includes text, "[stderr]\ntest failure"
  end

  def test_formats_scalar_tool_response
    text = render(HookFormatter.post_tool_message(
      hook_event('PostToolUse', 'tool_name' => 'Bash', 'tool_response' => 'completed')
    ))

    assert_includes text, "[output]\ncompleted"
  end

  def test_keeps_legacy_tool_payload_compatibility
    pre_text = render(HookFormatter.pre_tool_message(
      hook_event('PreToolUse', 'tool_name' => 'Bash', 'command' => 'pwd')
    ))
    post_text = render(HookFormatter.post_tool_message(
      hook_event('PostToolUse', 'tool_name' => 'Bash', 'output' => '/tmp', 'exit_code' => 0)
    ))

    assert_includes pre_text, '$ pwd'
    assert_includes post_text, '[exit_code] 0'
    assert_includes post_text, "[output]\n/tmp"
  end

  def test_formats_permission_request
    text = render(HookFormatter.permission_request_message(
      hook_event(
        'PermissionRequest',
        'tool_name' => 'Bash',
        'tool_input' => { 'description' => 'Allow network access?' }
      )
    ))

    assert_includes text, 'approval required: Bash'
    assert_includes text, 'Allow network access?'
  end

  def test_uses_raw_payload_only_for_unrecognized_debug_details
    pre_text = render(HookFormatter.pre_tool_message(
      hook_event('PreToolUse', 'tool_name' => 'Read', 'tool_input' => { 'path' => '/tmp/file' })
    ))
    post_text = render(HookFormatter.post_tool_message(
      hook_event('PostToolUse', 'tool_name' => 'Read', 'tool_response' => { 'metadata' => true })
    ))

    assert_includes pre_text, '"path": "/tmp/file"'
    assert_includes post_text, '"metadata": true'
  end

  private

  def render(message)
    CodexNotify::MessageFormatter.chunks(message).to_a.fetch(0)
  end

  def hook_event(event_name, fields)
    CodexNotify::HookInputValidator.validate(
      event_name:,
      payload: { 'session_id' => 'session-1' }.merge(fields)
    )
  end
end
