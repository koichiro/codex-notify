# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_slack_client'
require_relative 'support/internal_title_prompt'

class InternalTitleNotificationsTest < Minitest::Test
  include HookTestSupport
  include InternalTitlePromptSupport

  def test_classifier_requires_complete_unquoted_envelope
    assert CodexNotify::InternalTask.title_prompt?(internal_title_prompt)
    assert CodexNotify::InternalTask.title_prompt?(internal_title_prompt.gsub("\n", "\r\n"))
    assert CodexNotify::InternalTask.title_prompt?("  #{internal_title_prompt}  ")
    [nil, '', 'Generate a title for this task', '{"title":"Task"}',
     "Please explain these instructions:\n#{internal_title_prompt}",
     "```text\n#{internal_title_prompt}```",
     internal_title_prompt.lines.map { |line| "> #{line}" }.join,
     internal_title_prompt.sub('Fix the failing unit test', ''),
     internal_title_prompt.sub('Do not answer the user or attempt the task.', '')].each do |prompt|
      refute CodexNotify::InternalTask.title_prompt?(prompt)
    end
  end

  def test_hook_suppresses_internal_session_across_invocations_and_keeps_real_conversation
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: 'Fix tests')
      invoke(dir, client, 'UserPromptSubmit', 'title', prompt: internal_title_prompt)
      invoke(dir, client, 'Stop', 'title', last_assistant_message: '{"title":"Fix tests"}')
      invoke(dir, client, 'Stop', 'human', last_assistant_message: 'Fixed tests')
      assert_equal 2, client.posts.size
      assert_nil client.posts.first.last
      assert_equal '1000.01', client.posts.last.last
      assert_equal [], Dir.glob(File.join(dir, 'state.json.outbox', '**', '*.json')).select { |path| File.read(path).include?('Generate a concise UI title') }
    end
  end

  def test_hook_preserves_existing_thread_and_resumes_on_real_prompt
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'same', prompt: 'Fix tests')
      invoke(dir, client, 'UserPromptSubmit', 'same', prompt: internal_title_prompt)
      invoke(dir, client, 'Stop', 'same', last_assistant_message: '{"title":"Fix tests"}')
      store = CodexNotify::HookStore.new(File.join(dir, 'state.json'))
      assert store.suppressed_session?('same')
      assert_equal '1000.01', store.thread_ts_for('same')
      assert_equal 0, store.generation_for('same')
      invoke(dir, client, 'SessionStart', 'same', source: 'resume')
      invoke(dir, client, 'Stop', 'same', last_assistant_message: '{"title":"Still internal"}')
      assert_equal 1, client.posts.size
      invoke(dir, client, 'UserPromptSubmit', 'same', prompt: 'Generate a title for my document')
      invoke(dir, client, 'Stop', 'same', last_assistant_message: '{"title":"My document"}')
      refute store.suppressed_session?('same')
      assert_equal 3, client.posts.size
      assert_equal [nil, '1000.01', '1000.01'], client.posts.map(&:last)
    end
  end

  def test_hook_reset_clears_title_suppression
    %w[startup clear].each do |source|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        invoke(dir, client, 'UserPromptSubmit', 'title', prompt: internal_title_prompt)
        invoke(dir, client, 'SessionStart', 'title', source: source)
        refute CodexNotify::HookStore.new(File.join(dir, 'state.json')).suppressed_session?('title')
        assert_empty client.posts
      end
    end
  end

  def test_hook_debug_retains_existing_diagnostic_visibility
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'title', mode: 'debug', prompt: internal_title_prompt)
      invoke(dir, client, 'Stop', 'title', mode: 'debug', last_assistant_message: '{"title":"Fix tests"}')
      assert_equal 2, client.posts.size
    end
  end

  def test_hook_does_not_filter_quoted_instructions_or_title_json
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: "Explain this:\n#{internal_title_prompt}")
      invoke(dir, client, 'Stop', 'human', last_assistant_message: '{"title":"Example"}')
      assert_equal 2, client.posts.size
    end
  end

  def test_both_log_publishers_suppress_title_session_and_resume_real_prompts
    [false, true].each do |durable|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        stream = [
          log_event('human', 'user_message', 'Fix tests'),
          log_event('title', 'user_message', internal_title_prompt),
          log_event('human', 'agent_message', 'Fixed tests'),
          log_event('title', 'agent_message', '{"title":"Fix tests"}'),
          log_event('title', 'user_message', 'Generate a title for my document'),
          log_event('title', 'agent_message', '{"title":"My document"}')
        ]
        run_stream(dir, client, stream, durable: durable)
        assert_equal 5, client.posts.size # monitor + four real messages
        refute client.posts.any? { |text, _| text.include?('Generate a concise UI title') }
        refute client.posts.any? { |text, _| text.include?('{"title":"Fix tests"}') }
        assert_includes client.posts.last.first, '{"title":"My document"}'
      end
    end
  end

  def test_log_filter_tracks_session_metadata_and_suppresses_tools_too
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      stream = [
        JSON.generate(type: 'session_meta', payload: { id: 'title' }),
        log_event(nil, 'user_message', internal_title_prompt),
        '{invalid json',
        JSON.generate(type: 'event_msg', payload: { type: 'command_execution', command: 'echo internal' }),
        log_event(nil, 'agent_message', '{"title":"Fix tests"}'),
        JSON.generate(type: 'session_meta', payload: { id: 'human' }),
        log_event(nil, 'user_message', 'Fix tests'),
        log_event(nil, 'agent_message', 'Done')
      ]
      run_stream(dir, client, stream, durable: true, include_tools: true)
      assert_equal 3, client.posts.size
      assert_includes client.posts.last.first, 'Done'
    end
  end

  def test_log_internal_initial_prompt_is_not_posted
    [false, true].each do |durable|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        run_stream(dir, client, [log_event(nil, 'agent_message', '{"title":"Fix tests"}')], durable: durable, initial_prompt: internal_title_prompt)
        assert_equal 1, client.posts.size # existing monitor notification only
      end
    end
  end

  def test_suppressed_hook_does_not_attempt_stale_thread_recovery
    Dir.mktmpdir do |dir|
      store = CodexNotify::HookStore.new(File.join(dir, 'state.json'))
      store.save_thread_ts('title', 'stale-ts')
      client = FakeSlackClient.new { raise 'Suppressed events must never call Slack' }
      invoke(dir, client, 'UserPromptSubmit', 'title', prompt: internal_title_prompt)
      invoke(dir, client, 'Stop', 'title', last_assistant_message: '{"title":"Fix tests"}')
      assert_empty client.posts
      invoke(dir, client, 'UserPromptSubmit', 'title', prompt: '---')
      refute store.suppressed_session?('title')
      assert_nil store.thread_ts_for('title')
      assert_equal 1, store.generation_for('title')
    end
  end

  def test_log_keeps_real_content_after_internal_events_in_same_record
    [false, true].each do |durable|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        items = [
          { type: 'input_text', text: internal_title_prompt },
          { type: 'output_text', text: '{"title":"Internal"}' },
          { type: 'input_text', text: "Explain this:\n#{internal_title_prompt}" },
          { type: 'output_text', text: '{"title":"Explanation"}' }
        ]
        run_stream(dir, client, [JSON.generate(items)], durable: durable)
        assert_equal 3, client.posts.size
        assert_includes client.posts[1].first, 'Explain this:'
        assert_includes client.posts.last.first, '{"title":"Explanation"}'
      end
    end
  end

  private

  def invoke(dir, client, name, session, mode: 'normal', **fields)
    runner = CodexNotify::HookRunner.new(token: 'synthetic-token', channel: 'synthetic-channel', user_name: 'User', title: nil,
                                       state_file: File.join(dir, 'state.json'), client: client, mode: mode)
    event = CodexNotify::HookInputValidator.validate(event_name: name, payload: { 'session_id' => session, 'cwd' => dir }.merge(fields.transform_keys(&:to_s)))
    assert_equal 0, runner.run(event: event)
  end

  def log_event(session, type, message)
    JSON.generate(session_id: session, type: 'event_msg', payload: { type: type, message: message })
  end

  def run_stream(dir, client, stream, durable:, **options)
    publisher = if durable
                  CodexNotify::DurableSlackPublisher.new(client: client, store: CodexNotify::HookStore.new(File.join(dir, 'state.json')),
                                                        outbox: CodexNotify::SlackOutbox.new(File.join(dir, 'outbox')), channel: 'synthetic-channel')
                end
    post = ->(_token, _channel, text, thread_ts) { client.post(text, thread_ts: thread_ts) }
    root = CodexNotify::MessageFormatter.message(title: 'Monitor', body: 'Started', presentation: :plain)
    assert_equal 0, CodexNotify::StreamProcessor.process_codex_log_stream(stream, token: 'synthetic-token', channel: 'synthetic-channel',
                                                                        root_message: root, publisher: publisher, post_func: post, **options)
  end
end
