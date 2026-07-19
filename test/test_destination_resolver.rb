# frozen_string_literal: true

require_relative 'test_helper'

class CodexNotifyDestinationResolverTest < Minitest::Test
  DestinationResolver = CodexNotify::DestinationResolver
  EnvSourceLoader = CodexNotify::EnvSourceLoader

  def test_named_destination_normalizes_and_prefers_profile_credentials
    process = source(
      :process,
      'SLACK_BOT_TOKEN' => 'xoxb-default',
      'SLACK_BOT_TOKEN__PROJECT_A' => 'xoxb-profile',
      'SLACK_CHANNEL__PROJECT_A' => 'CPROJECT'
    )
    sources = source_set(process)

    result = resolver(sources).resolve(destination: ' project_a ', token: nil, channel: nil)

    assert_equal 'PROJECT_A', result.destination
    assert_equal 'xoxb-profile', result.token
    assert_equal 'CPROJECT', result.channel
    assert_same process, result.token_source
    assert_same process, result.channel_source
  end

  def test_named_destination_falls_back_to_default_token_and_prefers_cli_values
    process = source(
      :process,
      'SLACK_BOT_TOKEN' => 'xoxb-default',
      'SLACK_CHANNEL__PROJECT_A' => 'CPROJECT'
    )
    sources = source_set(process)

    fallback = resolver(sources).resolve(destination: 'PROJECT_A', token: nil, channel: nil)
    cli = resolver(sources).resolve(destination: 'PROJECT_A', token: 'xoxb-cli', channel: 'CCLI')

    assert_equal 'xoxb-default', fallback.token
    assert_equal 'xoxb-cli', cli.token
    assert_equal 'CCLI', cli.channel
    assert_nil cli.token_source
    assert_nil cli.channel_source
  end

  def test_destination_selection_uses_source_precedence
    process = source(:process, 'CODEX_NOTIFY_DESTINATION' => 'PROCESS', 'SLACK_CHANNEL__PROCESS' => 'CPROCESS')
    tool = source(:tool, 'CODEX_NOTIFY_DESTINATION' => 'TOOL', 'SLACK_BOT_TOKEN' => 'xoxb-tool')
    sources = source_set(process, tool)

    result = resolver(sources).resolve(destination: nil, token: nil, channel: nil)

    assert_equal 'PROCESS', result.destination
    assert_equal 'CPROCESS', result.channel
  end

  def test_repository_may_select_but_not_define_a_profile
    process = source(:process, 'SLACK_BOT_TOKEN' => 'xoxb-trusted')
    repository = source(
      :repository,
      'CODEX_NOTIFY_DESTINATION' => 'PROJECT_A',
      'SLACK_CHANNEL__PROJECT_A' => 'CUNTRUSTED'
    )
    all_sources = source_set(process, repository)
    trusted_sources = source_set(process)

    error = assert_raises(DestinationResolver::Error) do
      resolver(all_sources, profile_sources: trusted_sources).resolve(destination: nil, token: nil, channel: nil)
    end

    assert_includes error.message, 'missing SLACK_CHANNEL__PROJECT_A'
    refute_includes error.message, 'CUNTRUSTED'
  end

  def test_named_destination_requires_profile_channel_even_with_cli_channel
    sources = source_set(source(:process, 'SLACK_BOT_TOKEN' => 'xoxb-default'))

    error = assert_raises(DestinationResolver::Error) do
      resolver(sources).resolve(destination: 'UNKNOWN', token: nil, channel: 'CCLI')
    end

    assert_includes error.message, 'missing SLACK_CHANNEL__UNKNOWN'
  end

  def test_named_destination_requires_token_after_fallback
    sources = source_set(source(:process, 'SLACK_CHANNEL__PROJECT_A' => 'CPROJECT'))

    error = assert_raises(DestinationResolver::Error) do
      resolver(sources).resolve(destination: 'PROJECT_A', token: nil, channel: nil)
    end

    assert_includes error.message, 'has no Slack bot token'
  end

  def test_invalid_destination_does_not_echo_input
    sources = source_set

    error = assert_raises(DestinationResolver::Error) do
      resolver(sources).resolve(destination: 'project-a', token: nil, channel: nil)
    end

    assert_includes error.message, 'only A-Z, 0-9, and _'
    refute_includes error.message, 'project-a'
  end

  def test_default_destination_returns_selected_source_metadata
    repository = source(:repository, 'SLACK_BOT_TOKEN' => 'xoxb-repository', 'SLACK_CHANNEL' => 'CREPOSITORY')
    sources = source_set(repository)

    result = resolver(sources).resolve(destination: nil, token: nil, channel: nil)

    assert_nil result.destination
    assert_equal 'xoxb-repository', result.token
    assert_equal 'CREPOSITORY', result.channel
    assert_same repository, result.token_source
    assert_same repository, result.channel_source
  end

  private

  def resolver(sources, profile_sources: sources, default_sources: sources)
    DestinationResolver.new(selection_sources: sources, profile_sources:, default_sources:)
  end

  def source(kind, values = {})
    EnvSourceLoader::Source.new(kind:, path: nil, values:)
  end

  def source_set(*sources)
    EnvSourceLoader::SourceSet.new(sources)
  end
end
