# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_slack_client'
require_relative 'support/internal_title_prompt'
require_relative 'support/composer_prediction_prompt'

class InternalTitleNotificationsTest < Minitest::Test
  include HookTestSupport
  include InternalTitlePromptSupport
  include ComposerPredictionPromptSupport

  def test_composer_classifier_requires_complete_unquoted_template
    [composer_prediction_prompt, composer_prediction_prompt.gsub("\n", "\r\n"),
     "  #{composer_prediction_prompt}  ", composer_prediction_prompt.split.join(' ')].each do |prompt|
      assert CodexNotify::InternalTask.composer_prediction_prompt?(prompt)
      assert_equal 'internal_composer_prediction', CodexNotify::InternalTask.suppression_reason(prompt)
    end
    [nil, '', 'Suggest my next message', '{"suggestion":null}',
     "Explain these instructions:\n#{composer_prediction_prompt}",
     "```text\n#{composer_prediction_prompt}```",
     composer_prediction_prompt.lines.map { |line| "> #{line}" }.join,
     composer_prediction_prompt.sub('240', '300'),
     composer_prediction_prompt.lines.first,
     "#{composer_prediction_prompt}\nPlease explain."].each do |prompt|
      refute CodexNotify::InternalTask.composer_prediction_prompt?(prompt)
      assert_nil CodexNotify::InternalTask.suppression_reason(prompt)
    end
  end

  def test_hook_composer_suppression_preserves_thread_and_resumes_real_prompts
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: 'Fix tests')
      invoke(dir, client, 'UserPromptSubmit', 'prediction', prompt: composer_prediction_prompt)
      invoke(dir, client, 'Stop', 'prediction', last_assistant_message: '{"suggestion":null}')
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: composer_prediction_prompt)
      invoke(dir, client, 'SessionStart', 'human', source: 'resume')
      invoke(dir, client, 'Stop', 'human', last_assistant_message: '{"suggestion":"Run tests"}')
      store = CodexNotify::HookStore.new(File.join(dir, 'state.json'))
      assert store.suppressed_session?('human')
      assert_equal '1000.01', store.thread_ts_for('human')
      assert_equal 0, store.generation_for('human')
      assert_equal 1, client.posts.size
      refute Dir.glob(File.join(dir, 'state.json.outbox', '**', '*.json')).any? { |path| File.read(path).include?('app-generated request') }
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: 'Suggest my next message')
      invoke(dir, client, 'Stop', 'human', last_assistant_message: '{"suggestion":"Run tests"}')
      refute store.suppressed_session?('human')
      assert_equal [nil, '1000.01', '1000.01'], client.posts.map(&:last)
    end
  end

  def test_hook_composer_reset_clears_suppression_without_posting
    %w[startup clear reset_prompt].each do |reset|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new { raise 'Suppressed events must never call Slack' }
        store = CodexNotify::HookStore.new(File.join(dir, 'state.json'))
        store.save_thread_ts('prediction', 'stale-ts')
        invoke(dir, client, 'UserPromptSubmit', 'prediction', prompt: composer_prediction_prompt)
        invoke(dir, client, 'Stop', 'prediction', last_assistant_message: '{"suggestion":null}')
        if reset == 'reset_prompt'
          invoke(dir, client, 'UserPromptSubmit', 'prediction', prompt: '---')
        else
          invoke(dir, client, 'SessionStart', 'prediction', source: reset)
        end
        refute store.suppressed_session?('prediction')
        assert_nil store.thread_ts_for('prediction')
        assert_empty client.posts
      end
    end
  end

  def test_hook_keeps_composer_debug_and_quoted_content_visible
    Dir.mktmpdir do |dir|
      client = FakeSlackClient.new
      invoke(dir, client, 'UserPromptSubmit', 'debug', mode: 'debug', prompt: composer_prediction_prompt)
      invoke(dir, client, 'Stop', 'debug', mode: 'debug', last_assistant_message: '{"suggestion":null}')
      invoke(dir, client, 'UserPromptSubmit', 'human', prompt: "Explain this:\n#{composer_prediction_prompt}")
      invoke(dir, client, 'Stop', 'human', last_assistant_message: '{"suggestion":null}')
      assert_equal 4, client.posts.size
    end
  end

  def test_both_log_publishers_suppress_composer_sessions_and_keep_real_content
    [false, true].each do |durable|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        stream = [
          log_event('human', 'user_message', 'Fix tests'),
          JSON.generate(type: 'session_meta', payload: { id: 'prediction' }),
          log_event(nil, 'user_message', composer_prediction_prompt),
          JSON.generate(type: 'event_msg', payload: { type: 'command_execution', command: 'echo internal' }),
          log_event(nil, 'agent_message', '{"suggestion":"Internal candidate"}'),
          log_event('human', 'agent_message', 'Fixed tests'),
          log_event('prediction', 'user_message', "Explain this:\n#{composer_prediction_prompt}"),
          log_event('prediction', 'agent_message', '{"suggestion":null}')
        ]
        run_stream(dir, client, stream, durable: durable, include_tools: true)
        assert_equal 5, client.posts.size
        refute client.posts.any? { |text, _| text.include?('Internal candidate') || text.include?('echo internal') }
        assert_includes client.posts[-2].first, 'Explain this:'
        assert_includes client.posts.last.first, '{"suggestion":null}'
      end
    end
  end

  def test_both_log_publishers_suppress_composer_initial_prompt
    [false, true].each do |durable|
      Dir.mktmpdir do |dir|
        client = FakeSlackClient.new
        run_stream(dir, client, [log_event(nil, 'agent_message', '{"suggestion":null}')],
                   durable: durable, initial_prompt: composer_prediction_prompt)
        assert_equal 1, client.posts.size
      end
    end
  end

  def test_log_initial_suppression_follows_the_first_identified_session
    [composer_prediction_prompt, internal_title_prompt].each do |prompt|
      [false, true].each do |durable|
        [false, true].each do |metadata_first|
          Dir.mktmpdir do |dir|
            client = FakeSlackClient.new
            if durable
              store = CodexNotify::HookStore.new(File.join(dir, 'state.json'))
              store.save_thread_ts(Digest::SHA256.hexdigest("log\0internal"), '1000.01')
            end
            stream = [log_event(nil, 'agent_message', 'Internal before ID')]
            stream << JSON.generate(type: 'session_meta', payload: { id: 'internal' }) if metadata_first
            stream.concat([
              log_event('internal', 'agent_message', 'Internal after ID'),
              log_event('other', 'user_message', 'Fix tests'),
              log_event('other', 'agent_message', 'Fixed tests'),
              log_event('internal', 'agent_message', 'Still internal'),
              log_event('internal', 'user_message', 'Continue with my task'),
              log_event('internal', 'agent_message', 'Continued')
            ])
            run_stream(dir, client, stream, durable: durable, initial_prompt: prompt)
            assert_equal 5, client.posts.size # monitor + four ordinary messages
            refute client.posts.any? { |text, _| text.include?('Internal') || text.include?('Still internal') }
            assert_includes client.posts[1].first, 'Fix tests'
            assert_includes client.posts[-2].first, 'Continue with my task'
            assert_includes client.posts.last.first, 'Continued'
          end
        end
      end
    end
  end

  def test_log_ordinary_prompt_clears_initial_suppression_before_or_with_session_id
    [nil, 'human'].each do |prompt_session|
      stream = [
        log_event(prompt_session, 'user_message', 'Fix tests'),
        log_event('human', 'agent_message', 'Fixed tests')
      ]
      suppressed_sessions = { '__default__' => true }
      events = CodexNotify::StreamProcessor.visible_log_events(stream, suppressed_sessions).flat_map(&:last)
      assert_equal %w[user assistant], events.map(&:first)
      assert_equal ['Fix tests', 'Fixed tests'], events.map { |_, text, _| text }
      refute suppressed_sessions['human']
      refute suppressed_sessions.key?('__default__')
    end
  end

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
