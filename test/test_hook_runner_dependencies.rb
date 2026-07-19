# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'test_helper'
require_relative 'support/fake_slack_client'

class HookRunnerDependenciesTest < Minitest::Test
  include HookTestSupport

  def test_production_dependencies_remain_the_default
    Dir.mktmpdir do |dir|
      runner = CodexNotify::HookRunner.new(
        token: 'token',
        channel: 'channel',
        user_name: 'Codex',
        title: nil,
        state_file: Pathname(dir).join('state.json')
      )
      store = runner.instance_variable_get(:@store)
      publisher = runner.instance_variable_get(:@publisher)

      assert_instance_of CodexNotify::HookStore, store
      assert_instance_of CodexNotify::SlackClient, publisher.instance_variable_get(:@client)
      assert_same store, publisher.instance_variable_get(:@store)
    end
  end

  def test_injected_client_and_store_are_used_together
    Dir.mktmpdir do |dir|
      default_state_file = Pathname(dir).join('default-state.json')
      injected_state_file = Pathname(dir).join('injected-state.json')
      store = CodexNotify::HookStore.new(injected_state_file)
      client = FakeSlackClient.new(root_ts: '2000.01')
      runner = CodexNotify::HookRunner.new(
        token: 'unused-token',
        channel: 'unused-channel',
        user_name: 'Codex',
        title: nil,
        state_file: default_state_file,
        client:,
        store:
      )
      event = CodexNotify::HookInputValidator.validate(
        event_name: 'UserPromptSubmit',
        payload: { 'session_id' => 'session-1', 'prompt' => 'hello' }
      )

      assert_equal 0, runner.run(event:)

      assert_equal 1, client.posts.length
      assert_equal '2000.01', JSON.parse(injected_state_file.read).dig('threads', 'session-1')
      refute default_state_file.exist?
    end
  end
end
