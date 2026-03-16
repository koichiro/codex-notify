# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_helper'

class CodexNotifySessionLogTest < Minitest::Test
  SessionLog = CodexNotify::SessionLog

  def test_session_id_from_path_uses_jsonl_basename
    assert_equal 'rollout-abc', SessionLog.session_id_from_path('/tmp/rollout-abc.jsonl')
  end

  def test_iter_follow_lines_reads_existing_content_once
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("line1\nline2\n")

      lines = SessionLog.iter_follow_lines(log_file, once: true, start_at_end: false, sleep_func: ->(_) {}).to_a
      assert_equal ["line1\n", "line2\n"], lines
    end
  end

  def test_iter_follow_lines_starts_at_end_when_following
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("old1\nold2\n")

      lines = SessionLog.iter_follow_lines(log_file, once: true, start_at_end: true, sleep_func: ->(_) {}).to_a
      assert_equal [], lines
    end
  end

  def test_find_latest_session_file_selects_most_recent
    with_tmpdir do |dir|
      older = dir.join('older.jsonl')
      newer_dir = dir.join('nested')
      newer_dir.mkpath
      newer = newer_dir.join('newer.jsonl')
      older.write('{}')
      newer.write('{}')
      File.utime(Time.at(1), Time.at(1), older)
      File.utime(Time.at(2), Time.at(2), newer)

      assert_equal newer, SessionLog.find_latest_session_file(dir)
    end
  end

  def test_session_id_from_log_reads_session_meta_payload_id
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"019cf6db-b66a-7ac1-9a32-f9dc59c137b6\"}}\n")

      assert_equal '019cf6db-b66a-7ac1-9a32-f9dc59c137b6', SessionLog.session_id_from_log(log_file)
    end
  end

  def test_session_id_from_log_returns_nil_when_no_session_id_exists
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"hello\"}}\n")

      assert_nil SessionLog.session_id_from_log(log_file)
    end
  end

  private

  def with_tmpdir
    Dir.mktmpdir do |dir|
      yield Pathname(dir)
    end
  end
end
