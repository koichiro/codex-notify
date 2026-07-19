# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tmpdir'

class HookRunnerConcurrencyTest < Minitest::Test
  def test_concurrent_events_create_only_one_root_for_the_same_session
    skip 'fork is not supported on this platform' unless Process.respond_to?(:fork)

    Dir.mktmpdir do |dir|
      state_file = Pathname(dir).join('state.json')
      posts_file = Pathname(dir).join('posts.jsonl')
      original_post = CodexNotify::SlackClient.instance_method(:post)

      without_warnings do
        CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
          File.open(posts_file, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
            file.flock(File::LOCK_EX)
            file.puts(JSON.generate({ 'text' => text, 'thread_ts' => thread_ts }))
          end
          { 'ok' => true, 'ts' => (thread_ts || '1000.01') }
        end
      end

      readers = []
      writers = []
      pids = 2.times.map do |index|
        reader, writer = IO.pipe
        readers << reader
        writers << writer

        fork do
          writers.each(&:close)
          reader.read(1)
          runner = CodexNotify::HookRunner.new(
            token: 'token',
            channel: 'channel',
            user_name: 'Codex',
            title: nil,
            state_file: state_file,
            mode: 'normal'
          )
          event = CodexNotify::HookInputValidator.validate(
            event_name: 'UserPromptSubmit',
            payload: { 'session_id' => 'session-1', 'prompt' => "prompt #{index}" }
          )
          runner.run(event:)
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
      posts = posts_file.each_line.map { |line| JSON.parse(line) }
      assert_equal 1, posts.count { |post| post['thread_ts'].nil? }
      assert_equal '1000.01', JSON.parse(state_file.read).dig('threads', 'session-1')
    ensure
      without_warnings { CodexNotify::SlackClient.send(:define_method, :post, original_post) } if original_post
      readers&.each { |reader| reader.close unless reader.closed? }
      writers&.each { |writer| writer.close unless writer.closed? }
      pids&.each { |pid| Process.wait(pid) rescue nil }
    end
  end

  private

  def without_warnings
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end
end
