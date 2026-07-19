# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'test_helper'

class HookPayloadCompatibilityTest < Minitest::Test
  def test_current_legacy_and_nested_payloads_produce_the_same_slack_output
    cases = [
      ['SessionStart', { 'source' => 'startup' }, { 'payload' => { 'source' => 'startup' } }],
      ['UserPromptSubmit', { 'prompt' => 'hello' }, { 'payload' => { 'prompt' => 'hello' } }],
      [
        'PreToolUse',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'pwd' } },
        { 'payload' => { 'tool_name' => 'Bash', 'command' => 'pwd' } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'stdout' => 'done', 'exitCode' => 0 } },
        { 'payload' => { 'tool_name' => 'Bash', 'output' => 'done', 'exit_code' => 0 } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } },
        { 'payload' => { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } } }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'output' => 'done' } },
        { 'tool_name' => 'Bash', 'tool_output' => 'done' }
      ],
      [
        'PostToolUse',
        { 'tool_name' => 'Bash', 'tool_response' => { 'stderr' => 'failed' } },
        { 'tool_name' => 'Bash', 'stderr' => 'failed' }
      ],
      [
        'PermissionRequest',
        { 'tool_name' => 'Bash', 'tool_input' => { 'description' => 'Allow?' } },
        { 'payload' => { 'tool_name' => 'Bash', 'tool_input' => { 'description' => 'Allow?' } } }
      ],
      [
        'Stop',
        { 'last_assistant_message' => 'done' },
        { 'payload' => { 'last_assistant_message' => 'done' } }
      ]
    ]

    cases.each do |event_name, current, compatible|
      assert_equal slack_posts(event_name, current), slack_posts(event_name, compatible), event_name
    end
  end

  private

  def slack_posts(event_name, fields)
    Dir.mktmpdir do |dir|
      state_file = Pathname(dir).join('state.json')
      state_file.write(JSON.generate('threads' => { 'session-1' => '1000.01' }))
      event = CodexNotify::HookInputValidator.validate(
        event_name:,
        payload: { 'session_id' => 'session-1', 'cwd' => '/tmp/app' }.merge(fields)
      )

      with_stubbed_posts do |posts|
        runner = CodexNotify::HookRunner.new(
          token: 'token',
          channel: 'channel',
          user_name: 'Codex',
          title: nil,
          state_file:,
          mode: 'debug'
        )
        assert_equal 0, runner.run(event:)
        posts
      end
    end
  end

  def with_stubbed_posts
    posts = []
    original_post = CodexNotify::SlackClient.instance_method(:post)
    without_warnings do
      CodexNotify::SlackClient.send(:define_method, :post) do |text, thread_ts: nil|
        posts << [text, thread_ts]
        { 'ok' => true, 'ts' => (thread_ts || '2000.01') }
      end
    end
    yield posts
  ensure
    without_warnings { CodexNotify::SlackClient.send(:define_method, :post, original_post) }
  end

  def without_warnings
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end
end
