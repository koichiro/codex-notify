# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyCLITest < Minitest::Test
  CLI = CodexNotify::CLI

  def setup
    @env_backup = ENV.to_h
  end

  def teardown
    ENV.replace(@env_backup)
  end

  def test_session_id_from_path_uses_jsonl_basename
    assert_equal 'rollout-abc', CLI.session_id_from_path('/tmp/rollout-abc.jsonl')
  end

  def test_getenv_any_returns_first_match
    ENV.delete('FIRST')
    ENV['SECOND'] = 'value'
    assert_equal 'value', CLI.getenv_any(%w[FIRST SECOND])
  end

  def test_load_env_file_sets_values
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-test\nSLACK_CHANNEL=C123\n")
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      CLI.load_env_file(env_file.to_s)

      assert_equal 'xoxb-test', ENV['SLACK_BOT_TOKEN']
      assert_equal 'C123', ENV['SLACK_CHANNEL']
    end
  end

  def test_load_env_file_does_not_override_existing_value
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-test\n")
      ENV['SLACK_BOT_TOKEN'] = 'existing'

      CLI.load_env_file(env_file.to_s)

      assert_equal 'existing', ENV['SLACK_BOT_TOKEN']
    end
  end

  def test_parse_args_uses_env_file_defaults
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-from-env\nSLACK_CHANNEL=CENV\nCODEX_NOTIFY_USER_NAME=alice\n")
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')
      ENV.delete('CODEX_NOTIFY_USER_NAME')

      args = CLI.parse_args(['--env-file', env_file.to_s])

      assert_equal 'xoxb-from-env', args.token
      assert_equal 'CENV', args.channel
      assert_equal 'alice', args.user_name
    end
  end

  def test_parse_args_prefers_cli_user_name_over_env
    ENV['CODEX_NOTIFY_USER_NAME'] = 'env-user'

    args = CLI.parse_args(['--user-name', 'cli-user'])

    assert_equal 'cli-user', args.user_name
  end

  def test_parse_args_uses_system_user_name_when_no_override_is_present
    ENV.delete('CODEX_NOTIFY_USER_NAME')

    original = CLI.method(:system_user_name)
    with_silenced_warnings do
      CLI.singleton_class.send(:define_method, :system_user_name) { 'local-user' }
    end
    begin
      args = CLI.parse_args([])
      assert_equal 'local-user', args.user_name
    ensure
      with_silenced_warnings do
        CLI.singleton_class.send(:define_method, :system_user_name, original)
      end
    end
  end

  def test_main_returns_error_without_credentials
    ENV.delete('SLACK_BOT_TOKEN')
    ENV.delete('SLACK_CHANNEL')
    err = StringIO.new

    exit_code = CLI.main(['--env-file', 'missing.env'], stderr: err)

    assert_equal 2, exit_code
    assert_includes err.string, 'need --token/--channel'
  end

  def test_main_returns_error_without_session_log
    with_tmpdir do |dir|
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      err = StringIO.new

      exit_code = CLI.main(['--env-file', 'missing.env', '--sessions-dir', dir.to_s, '--once'], stderr: err)

      assert_equal 2, exit_code
      assert_includes err.string, 'no Codex session log file found'
    end
  end

  def test_main_exits_cleanly_on_interrupt
    with_tmpdir do |dir|
      session_file = dir.join('rollout.jsonl')
      session_file.write('')
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-token'
      ENV['SLACK_CHANNEL'] = 'C123'
      err = StringIO.new

      original = CLI.method(:process_codex_log_stream)
      with_silenced_warnings do
        CLI.singleton_class.send(:define_method, :process_codex_log_stream) { |*| raise Interrupt }
      end
      begin
        exit_code = CLI.main(['--env-file', 'missing.env', '--session-file', session_file.to_s], stderr: err)
        assert_equal 0, exit_code
      ensure
        with_silenced_warnings do
          CLI.singleton_class.send(:define_method, :process_codex_log_stream, original)
        end
      end

      assert_includes err.string, 'Stopped.'
    end
  end

  def test_process_events_posts_root_assistant_and_finish
    posts = []
    fake_post = lambda do |token, channel, text, thread_ts = nil|
      posts << { token:, channel:, text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new([
                           '{"type":"turn.started"}',
                           '{"type":"item.completed","item":{"type":"assistant_message","text":"hello"}}'
                         ].join("\n"))

    exit_code = CLI.process_events(
      events,
      token: 'xoxb-token',
      channel: 'C123',
      root_text: 'root',
      initial_prompt: 'fix failing test',
      post_func: fake_post,
      sleep_func: ->(_) {}
    )

    assert_equal 0, exit_code
    assert_equal 'root', posts[0][:text]
    assert_equal '123.456', posts[1][:thread_ts]
    assert_includes posts[1][:text], '*user*'
    assert_includes posts[1][:text], 'fix failing test'
    assert_includes posts[2][:text], '*assistant*'
    assert_includes posts[2][:text], 'hello'
    assert_includes posts[3][:text], 'Codex run finished'
  end

  def test_process_events_does_not_post_turn_started
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    CLI.process_events(StringIO.new('{"type":"turn.started"}'),
                       token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_equal 'root', posts[0]
    assert_includes posts[1], 'Codex run finished'
  end

  def test_process_events_skips_invalid_json
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    CLI.process_events(StringIO.new("not-json\n\n"),
                       token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_equal 'root', posts[0]
    assert_includes posts[1], 'Codex run finished'
  end

  def test_process_events_includes_tools_when_enabled
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0,"stdout":"ok","stderr":""}}')
    CLI.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('command_execution') })
    assert(posts.any? { |post| post.include?("COMMAND:\nls") })
  end

  def test_process_events_ignores_tools_when_disabled
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0}}')
    CLI.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       include_tools: false, post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 2, posts.length
    assert_includes posts[-1], 'Codex run finished'
  end

  def test_process_events_handles_user_message
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"turn.started"}' + "\n" + '{"type":"item.completed","item":{"type":"user_message","text":"please fix it"}}')
    CLI.process_events(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('*user*') })
    assert(posts.any? { |post| post.include?('please fix it') })
  end

  def test_process_events_posts_concise_failure
    posts = []
    fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
      posts << text
      { 'ok' => true, 'ts' => '123.456' }
    end

    CLI.process_events(StringIO.new("{\"type\":\"turn.started\"}\n{\"type\":\"turn.failed\"}"),
                       token: 'xoxb-token', channel: 'C123', root_text: 'root',
                       post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post.include?('*system*') })
    assert(posts.any? { |post| post.include?('turn 1 failed') })
  end

  def test_iter_follow_lines_reads_existing_content_once
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("line1\nline2\n")

      lines = CLI.iter_follow_lines(log_file, once: true, start_at_end: false, sleep_func: ->(_) {}).to_a
      assert_equal ["line1\n", "line2\n"], lines
    end
  end

  def test_iter_follow_lines_starts_at_end_when_following
    with_tmpdir do |dir|
      log_file = dir.join('session.jsonl')
      log_file.write("old1\nold2\n")

      lines = CLI.iter_follow_lines(log_file, once: true, start_at_end: true, sleep_func: ->(_) {}).to_a
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

      assert_equal newer, CLI.find_latest_session_file(dir)
    end
  end

  def test_process_codex_log_stream_posts_user_and_assistant_messages
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "123.45#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","payload":{"type":"user_message","message":"fix tests"}}',
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"working on it"}}'
                         ].join("\n"))

    exit_code = CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                             post_func: fake_post, sleep_func: ->(_) {})

    assert_equal 0, exit_code
    assert_equal 'root', posts[0][:text]
    assert_nil posts[1][:thread_ts]
    assert_includes posts[1][:text], '*user*'
    assert_includes posts[1][:text], 'fix tests'
    assert_equal posts[1][:ts], posts[2][:thread_ts]
    assert_includes posts[2][:text], '*assistant*'
    assert_includes posts[2][:text], 'working on it'
  end

  def test_process_codex_log_stream_uses_custom_user_name
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"user_message","message":"fix tests"}}')

    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 user_name: 'koichiro', post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*koichiro*') })
  end

  def test_process_codex_log_stream_posts_task_complete_message
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}')
    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*assistant*') && post[:text].include?('done') })
  end

  def test_process_codex_log_stream_posts_tool_when_enabled
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new('{"type":"event_msg","payload":{"type":"command_execution","command":"ls","stdout":"ok","exit_code":0}}')
    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

    assert(posts.any? { |post| post[:text].include?('*tool*') })
    assert(posts.any? { |post| post[:text].include?('```') })
  end

  def test_extract_events_reads_message_parts
    obj = {
      'type' => 'response_item',
      'payload' => {
        'type' => 'message',
        'role' => 'assistant',
        'content' => [
          { 'type' => 'output_text', 'text' => 'part one' },
          { 'type' => 'output_text', 'text' => 'part two' }
        ]
      }
    }

    events = CLI.extract_events(obj)
    assert_includes events, ['assistant', 'part one', 'output_text']
    assert_includes events, ['assistant', 'part two', 'output_text']
  end

  def test_extract_events_reads_payload_input_text
    obj = { 'type' => 'x', 'payload' => { 'type' => 'input_text', 'text' => 'hello' } }
    assert_includes CLI.extract_events(obj), ['user', 'hello', 'input_text']
  end

  def test_extract_events_reads_direct_output_text
    obj = { 'type' => 'output_text', 'text' => 'done' }
    assert_includes CLI.extract_events(obj), ['assistant', 'done', 'output_text']
  end

  def test_extract_events_reads_nested_user_message
    obj = {
      'type' => 'wrapper',
      'message' => {
        'type' => 'event_msg',
        'payload' => { 'type' => 'user_message', 'message' => 'hello' }
      }
    }

    assert_includes CLI.extract_events(obj), ['user', 'hello', 'input_text']
  end

  def test_extract_events_reads_tool_from_nested_payload
    obj = {
      'type' => 'wrapper',
      'payload' => {
        'type' => 'something',
        'tool_result' => { 'type' => 'tool_result', 'name' => 'x', 'output' => { 'ok' => true } }
      }
    }

    assert(CLI.extract_events(obj).any? { |event| event[0] == 'tool' })
  end

  def test_extract_session_id_reads_nested_session_id
    obj = {
      'type' => 'event_msg',
      'payload' => {
        'type' => 'user_message',
        'message' => 'hello',
        'session_id' => 'sess-1'
      }
    }

    assert_equal 'sess-1', CLI.extract_session_id(obj)
  end

  def test_process_codex_log_stream_deduplicates_same_message
    posts = []
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      posts << { text:, thread_ts: }
      { 'ok' => true, 'ts' => '123.456' }
    end

    events = StringIO.new([
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}',
                           '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}'
                         ].join("\n"))

    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 post_func: fake_post, sleep_func: ->(_) {})

    assistant_posts = posts.select { |post| post[:text].include?('*assistant*') }
    assert_equal 1, assistant_posts.length
  end

  def test_process_codex_log_stream_reuses_thread_for_same_session_id
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "200.0#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"first"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply1"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"second"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply2"}}'
                         ].join("\n"))

    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 post_func: fake_post, sleep_func: ->(_) {})

    first_user = posts[1]
    first_reply = posts[2]
    second_user = posts[3]
    second_reply = posts[4]

    assert_nil first_user[:thread_ts]
    assert_equal first_user[:ts], first_reply[:thread_ts]
    assert_equal first_user[:ts], second_user[:thread_ts]
    assert_equal first_user[:ts], second_reply[:thread_ts]
  end

  def test_process_codex_log_stream_starts_new_thread_for_different_session_id
    posts = []
    counter = 0
    fake_post = lambda do |_token, _channel, text, thread_ts = nil|
      counter += 1
      ts = "300.0#{counter}"
      posts << { text:, thread_ts:, ts: }
      { 'ok' => true, 'ts' => ts }
    end

    events = StringIO.new([
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"user_message","message":"first"}}',
                           '{"type":"event_msg","session_id":"session-1","payload":{"type":"agent_message","message":"reply1"}}',
                           '{"type":"event_msg","session_id":"session-2","payload":{"type":"user_message","message":"second"}}',
                           '{"type":"event_msg","session_id":"session-2","payload":{"type":"agent_message","message":"reply2"}}'
                         ].join("\n"))

    CLI.process_codex_log_stream(events, token: 'xoxb-token', channel: 'C123', root_text: 'root',
                                 post_func: fake_post, sleep_func: ->(_) {})

    first_user = posts[1]
    first_reply = posts[2]
    second_user = posts[3]
    second_reply = posts[4]

    assert_nil first_user[:thread_ts]
    assert_equal first_user[:ts], first_reply[:thread_ts]
    assert_nil second_user[:thread_ts]
    assert_equal second_user[:ts], second_reply[:thread_ts]
  end

  def test_process_events_posts_other_tool_types
    %w[file_change web_search something_else].each do |item_type|
      posts = []
      fake_post = lambda do |_token, _channel, text, _thread_ts = nil|
        posts << text
        { 'ok' => true, 'ts' => '123.456' }
      end

      payload = "{\"type\":\"item.completed\",\"item\":{\"type\":\"#{item_type}\",\"value\":\"x\"}}"
      CLI.process_events(StringIO.new(payload), token: 'xoxb-token', channel: 'C123', root_text: 'root',
                         include_tools: true, post_func: fake_post, sleep_func: ->(_) {})

      assert_operator posts.length, :>=, 2
    end
  end

  private

  def with_tmpdir
    Dir.mktmpdir do |dir|
      yield Pathname(dir)
    end
  end

  def with_silenced_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end
end
