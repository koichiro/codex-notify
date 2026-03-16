# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyMessageFormatterTest < Minitest::Test
  Formatter = CodexNotify::MessageFormatter

  def test_chunk_text_splits_long_text
    assert_equal %w[aaaa aaaa aa], Formatter.chunk_text('a' * 10, 4).to_a
  end

  def test_fmt_block_wraps_title_and_body
    assert_equal "*title*\n```body```", Formatter.fmt_block('title', 'body')
  end

  def test_build_root_text_is_minimal
    text = Formatter.build_root_text('title', '/tmp/project', user_name: 'alice', session_id: 'session-123')
    assert_includes text, 'Codex log monitoring started.'
    assert_includes text, 'CWD: /tmp/project'
    assert_includes text, 'User: alice'
    assert_includes text, 'Session ID: session-123'
  end

  def test_fmt_plain_wraps_title_and_body
    assert_equal "*user*\nhello", Formatter.fmt_plain('user', 'hello')
  end
end
