# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyHookFormatterTest < Minitest::Test
  HookFormatter = CodexNotify::HookFormatter

  def test_formats_current_pre_tool_use_payload
    text = HookFormatter.format_pre_tool(
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'bundle exec rake' }
    )

    assert_includes text, '$ bundle exec rake'
    refute_includes text, '"command"'
  end

  def test_formats_current_post_tool_use_payload
    text = HookFormatter.format_post_tool(
      'tool_name' => 'Bash',
      'tool_response' => {
        'exit_code' => 1,
        'stdout' => 'test output',
        'stderr' => 'test failure'
      }
    )

    assert_includes text, '[exit_code] 1'
    assert_includes text, "[output]\ntest output"
    assert_includes text, "[stderr]\ntest failure"
  end

  def test_formats_scalar_tool_response
    text = HookFormatter.format_post_tool('tool_response' => 'completed')

    assert_includes text, "[output]\ncompleted"
  end

  def test_keeps_legacy_tool_payload_compatibility
    pre_text = HookFormatter.format_pre_tool('command' => 'pwd')
    post_text = HookFormatter.format_post_tool('output' => '/tmp', 'exit_code' => 0)

    assert_includes pre_text, '$ pwd'
    assert_includes post_text, '[exit_code] 0'
    assert_includes post_text, "[output]\n/tmp"
  end
end
