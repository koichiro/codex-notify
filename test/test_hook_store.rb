# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tmpdir'

class HookStoreTest < Minitest::Test
  def test_concurrent_processes_preserve_updates_for_every_session
    skip 'fork is not supported on this platform' unless Process.respond_to?(:fork)

    Dir.mktmpdir do |dir|
      state_file = Pathname(dir).join('state.json')
      readers = []
      writers = []
      pids = 12.times.map do |index|
        reader, writer = IO.pipe
        readers << reader
        writers << writer

        fork do
          writers.each(&:close)
          reader.read(1)
          CodexNotify::HookStore.new(state_file).save_thread_ts("session-#{index}", "ts-#{index}")
          exit! 0
        end
      end

      readers.each(&:close)
      writers.each do |writer|
        writer.write('.')
        writer.close
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }

      assert statuses.all?(&:success?)
      expected = 12.times.to_h { |index| ["session-#{index}", "ts-#{index}"] }
      assert_equal expected, JSON.parse(state_file.read).fetch('threads')
    ensure
      readers&.each { |reader| reader.close unless reader.closed? }
      writers&.each { |writer| writer.close unless writer.closed? }
      pids&.each { |pid| Process.wait(pid) rescue nil }
    end
  end

  def test_same_session_lock_blocks_another_process_until_release
    skip 'fork is not supported on this platform' unless Process.respond_to?(:fork)

    pid = nil
    Dir.mktmpdir do |dir|
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))
      started_reader, started_writer = IO.pipe
      acquired_reader, acquired_writer = IO.pipe

      store.with_session_lock('session-1') do
        pid = fork do
          started_reader.close
          acquired_reader.close
          started_writer.write('.')
          started_writer.close
          store.with_session_lock('session-1') { acquired_writer.write('.') }
          acquired_writer.close
          exit! 0
        end

        started_writer.close
        acquired_writer.close
        assert_equal '.', started_reader.read(1)
        assert_nil IO.select([acquired_reader], nil, nil, 0.1)
      end

      assert_equal '.', acquired_reader.read(1)
      assert Process.wait2(pid).last.success?
    ensure
      [started_reader, started_writer, acquired_reader, acquired_writer].compact.each do |io|
        io.close unless io.closed?
      end
      begin
        Process.wait(pid) if pid
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def test_different_session_locks_do_not_block_each_other
    skip 'fork is not supported on this platform' unless Process.respond_to?(:fork)

    pid = nil
    Dir.mktmpdir do |dir|
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))
      acquired_reader, acquired_writer = IO.pipe

      store.with_session_lock('session-1') do
        pid = fork do
          acquired_reader.close
          store.with_session_lock('session-2') { acquired_writer.write('.') }
          acquired_writer.close
          exit! 0
        end

        acquired_writer.close
        assert IO.select([acquired_reader], nil, nil, 1)
        assert_equal '.', acquired_reader.read(1)
      end

      assert Process.wait2(pid).last.success?
    ensure
      [acquired_reader, acquired_writer].compact.each { |io| io.close unless io.closed? }
      begin
        Process.wait(pid) if pid
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def test_session_lock_is_released_after_an_exception
    Dir.mktmpdir do |dir|
      store = CodexNotify::HookStore.new(Pathname(dir).join('state.json'))

      assert_raises(RuntimeError) do
        store.with_session_lock('session-1') { raise 'boom' }
      end

      acquired = false
      store.with_session_lock('session-1') { acquired = true }
      assert acquired
    end
  end
end
