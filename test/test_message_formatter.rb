# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyMessageFormatterTest < Minitest::Test
  Formatter = CodexNotify::MessageFormatter

  def test_plain_chunks_account_for_formatting_overhead_at_boundaries
    exact = Formatter.message(title: 't', body: 'a' * 6, presentation: :plain)
    over = Formatter.message(title: 't', body: 'a' * 7, presentation: :plain)

    assert_equal ["*t*\n#{'a' * 6}"], Formatter.chunks(exact, max_length: 10).to_a
    assert_equal ["*t*\n#{'a' * 6}", "*(cont…*\na"], Formatter.chunks(over, max_length: 10).to_a
  end

  def test_block_chunks_are_self_contained_and_reconstruct_the_body
    body = 'a' * 10
    message = Formatter.message(title: 'tool', body:, presentation: :block)
    chunks = Formatter.chunks(message, max_length: 18).to_a

    assert_equal body, reconstructed_body(chunks, :block)
    assert chunks.all? { |chunk| chunk.length <= 18 }
    assert chunks.all? { |chunk| chunk.split("\n", 2).last.start_with?('```') }
    assert chunks.all? { |chunk| chunk.end_with?('```') }
    assert_equal '*tool*', chunks.first.lines.first.chomp
    assert_equal '*(cont.)*', chunks.last.lines.first.chomp
  end

  def test_long_plain_message_uses_continuation_titles
    message = Formatter.message(title: 'user', body: 'abcdefghij', presentation: :plain)
    chunks = Formatter.chunks(message, max_length: 12).to_a

    assert_equal 'abcdefghij', reconstructed_body(chunks, :plain)
    assert_equal '*user*', chunks.first.lines.first.chomp
    assert_equal '*(cont.)*', chunks[1].lines.first.chomp
    assert chunks.all? { |chunk| chunk.length <= 12 }
  end

  def test_multibyte_text_remains_valid_and_reconstructs_exactly
    body = '日本語🙂' * 2_000
    message = Formatter.message(title: 'assistant', body:, presentation: :plain)
    chunks = Formatter.chunks(message).to_a

    assert_equal body, reconstructed_body(chunks, :plain)
    assert chunks.all?(&:valid_encoding?)
    assert chunks.all? { |chunk| chunk.length <= Formatter::SLACK_SAFE_LENGTH }
  end

  def test_chunks_normalize_crlf_like_the_previous_chunker
    message = Formatter.message(title: 'user', body: "one\r\ntwo", presentation: :plain)

    assert_equal "one\ntwo", reconstructed_body(Formatter.chunks(message).to_a, :plain)
  end

  def test_empty_body_produces_one_formatted_chunk
    message = Formatter.message(title: 'assistant', body: '', presentation: :plain)

    assert_equal ["*assistant*\n"], Formatter.chunks(message).to_a
  end

  def test_long_title_is_truncated_without_dropping_body
    message = Formatter.message(title: 'very-long-title', body: 'body', presentation: :plain)
    chunks = Formatter.chunks(message, max_length: 8).to_a

    assert_equal 'body', reconstructed_body(chunks, :plain)
    assert chunks.all? { |chunk| chunk.length <= 8 }
  end

  def test_minimum_plain_length_still_makes_progress
    message = Formatter.message(title: 'title', body: 'ab', presentation: :plain)
    chunks = Formatter.chunks(message, max_length: 4).to_a

    assert_equal 'ab', reconstructed_body(chunks, :plain)
    assert chunks.all? { |chunk| chunk.length <= 4 }
  end

  def test_rejects_unknown_presentation
    error = assert_raises(ArgumentError) do
      Formatter.message(title: 'title', body: 'body', presentation: :unknown)
    end

    assert_includes error.message, 'unsupported message presentation'
  end

  def test_rejects_max_length_too_small_for_format
    message = Formatter.message(title: 'tool', body: 'body', presentation: :block)

    assert_raises(ArgumentError) { Formatter.chunks(message, max_length: 9).to_a }
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

  def test_build_root_message_preserves_short_root_output
    message = Formatter.build_root_message('title', '/tmp/project', user_name: 'alice', session_id: 'session-123')

    assert_equal Formatter.build_root_text('title', '/tmp/project', user_name: 'alice', session_id: 'session-123'),
                 Formatter.chunks(message).to_a.fetch(0)
  end

  def test_fmt_plain_wraps_title_and_body
    assert_equal "*user*\nhello", Formatter.fmt_plain('user', 'hello')
  end

  private

  def reconstructed_body(chunks, presentation)
    chunks.map do |chunk|
      body = chunk.split("\n", 2).fetch(1)
      presentation == :block ? body.delete_prefix('```').delete_suffix('```') : body
    end.join
  end
end
