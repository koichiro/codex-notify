# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyConfigDiagnosticsTest < Minitest::Test
  ConfigDiagnostics = CodexNotify::ConfigDiagnostics

  def test_warns_when_env_file_is_group_or_world_readable_without_showing_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.env')
      File.write(path, "SLACK_BOT_TOKEN=xoxb-sensitive-value\n")
      File.chmod(0o644, path)
      stderr = StringIO.new

      ConfigDiagnostics.warn_if_env_file_insecure(path, stderr:)

      assert_includes stderr.string, 'permissions 0644'
      assert_includes stderr.string, "chmod 600 #{path}"
      refute_includes stderr.string, 'xoxb-sensitive-value'
    end
  end

  def test_does_not_warn_when_env_file_is_owner_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.env')
      File.write(path, "SLACK_BOT_TOKEN=xoxb-sensitive-value\n")
      File.chmod(0o600, path)
      stderr = StringIO.new

      ConfigDiagnostics.warn_if_env_file_insecure(path, stderr:)

      assert_empty stderr.string
    end
  end

  def test_ignores_env_file_stat_errors
    stderr = StringIO.new

    result = ConfigDiagnostics.warn_if_env_file_insecure('/missing/config.env', stderr:)

    assert_nil result
    assert_empty stderr.string
  end

  def test_warns_about_deprecated_cli_token_without_accepting_its_value
    stderr = StringIO.new

    ConfigDiagnostics.warn_deprecated_cli_token(stderr:)

    assert_includes stderr.string, '--token is deprecated'
    assert_includes stderr.string, 'process lists and shell history'
    assert_raises(ArgumentError) { ConfigDiagnostics.warn_deprecated_cli_token }
  end

  def test_warns_about_deprecated_repository_credentials_using_metadata_only
    stderr = StringIO.new

    ConfigDiagnostics.warn_deprecated_repository_credentials(
      '/project/.env',
      %w[SLACK_BOT_TOKEN SLACK_CHANNEL],
      stderr:
    )

    assert_includes stderr.string, 'SLACK_BOT_TOKEN and SLACK_CHANNEL'
    assert_includes stderr.string, '/project/.env'
    refute_includes stderr.string, 'xoxb-sensitive-value'
    refute_includes stderr.string, 'CSENSITIVE'
  end

  def test_warns_about_ignored_repository_credentials_with_optional_policy
    legacy_stderr = StringIO.new
    restricted_stderr = StringIO.new

    ConfigDiagnostics.warn_ignored_repository_credentials(
      '/project/.env',
      ['SLACK_CHANNEL__PROJECT_A'],
      stderr: legacy_stderr
    )
    ConfigDiagnostics.warn_ignored_repository_credentials(
      '/project/.env',
      %w[SLACK_BOT_TOKEN SLACK_CHANNEL],
      policy: 'restricted',
      stderr: restricted_stderr
    )

    assert_includes legacy_stderr.string, 'ignored SLACK_CHANNEL__PROJECT_A'
    refute_includes legacy_stderr.string, 'under the restricted policy'
    assert_includes restricted_stderr.string, 'under the restricted policy'
    refute_includes restricted_stderr.string, 'xoxb-sensitive-value'
    refute_includes restricted_stderr.string, 'CSENSITIVE'
  end
end
