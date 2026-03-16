# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyLogEventParserTest < Minitest::Test
  Parser = CodexNotify::LogEventParser

  def test_as_text_handles_non_string_values
    assert_equal '', Parser.as_text(nil)
    assert_equal '{"a":1}', Parser.as_text({ 'a' => 1 })
    assert_equal '12', Parser.as_text(12)
  end

  def test_pretty_json_falls_back_to_json_string
    assert_includes Parser.pretty_json({ 'a' => 1 }), '"a": 1'
  end

  def test_extract_session_id_finds_nested_id
    payload = { 'outer' => { 'conversationId' => 'session-123' } }

    assert_equal 'session-123', Parser.extract_session_id(payload)
  end

  def test_extract_session_id_prefers_session_meta_payload_id
    payload = {
      'type' => 'session_meta',
      'payload' => { 'id' => '019cf6db-b66a-7ac1-9a32-f9dc59c137b6' },
      'session_id' => 'other-session'
    }

    assert_equal '019cf6db-b66a-7ac1-9a32-f9dc59c137b6', Parser.extract_session_id(payload)
  end

  def test_tool_event_type_recognizes_command_execution
    assert_equal true, Parser.tool_event_type?('command_execution')
    assert_equal false, Parser.tool_event_type?('other')
  end

  def test_format_tool_payload_formats_command
    payload = { 'command' => %w[ls -la], 'exit_code' => 0, 'stdout' => 'ok', 'stderr' => '' }
    text = Parser.format_tool_payload(payload)
    assert_includes text, '$ ls -la'
    assert_includes text, '[exit_code] 0'
    assert_includes text, '[stdout]'
  end

  def test_format_tool_payload_formats_generic_tool
    payload = { 'name' => 'web_search', 'arguments' => { 'q' => 'x' }, 'result' => { 'ok' => true } }
    text = Parser.format_tool_payload(payload)
    assert_includes text, '[tool] web_search'
    assert_includes text, '[args]'
    assert_includes text, '[result]'
  end

  def test_extract_events_reads_user_and_assistant_messages
    event = {
      'payload' => {
        'type' => 'message',
        'content' => [
          { 'type' => 'input_text', 'text' => 'fix tests' },
          { 'type' => 'output_text', 'text' => 'working on it' }
        ]
      }
    }

    assert_equal [
      ['user', 'fix tests', 'input_text'],
      ['assistant', 'working on it', 'output_text']
    ], Parser.extract_events(event)
  end

  def test_extract_events_formats_tool_payloads
    event = {
      'payload' => {
        'type' => 'tool_call',
        'name' => 'web_search',
        'arguments' => { 'q' => 'x' }
      }
    }

    extracted = Parser.extract_events(event)

    assert_equal 1, extracted.length
    assert_equal 'tool', extracted[0][0]
    assert_equal 'tool', extracted[0][2]
    assert_includes extracted[0][1], 'web_search'
  end
end
