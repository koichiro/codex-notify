# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require_relative 'test_helper'

class CodexNotifyHookConfigTest < Minitest::Test
  HookConfig = CodexNotify::HookConfig

  def setup
    @env_backup = ENV.to_h
  end

  def teardown
    ENV.replace(@env_backup)
  end

  def test_parse_args_falls_back_to_app_root_env_for_relative_path
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-hook\nSLACK_CHANNEL=CHOOK\nCODEX_NOTIFY_USER_NAME=hook-user\n")
      env_file.chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')
      ENV.delete('CODEX_NOTIFY_USER_NAME')

      original = HookConfig.method(:app_root)
      Dir.mktmpdir do |cwd|
        Dir.chdir(cwd) do
          with_silenced_warnings do
            HookConfig.singleton_class.send(:define_method, :app_root) { dir }
          end

          stderr = StringIO.new
          args = HookConfig.parse_args([], stderr:)
          assert_equal 'xoxb-hook', args.token
          assert_equal 'CHOOK', args.channel
          assert_equal 'hook-user', args.user_name
          assert_includes stderr.string, 'legacy codex-notify env file'
          refute_includes stderr.string, 'xoxb-hook'
        end
      end
    ensure
      with_silenced_warnings do
        HookConfig.singleton_class.send(:define_method, :app_root, original)
      end
    end
  end

  def test_parse_args_merges_cwd_and_app_root_relative_paths
    with_tmpdir do |app_root|
      app_root.join('.env').write("SLACK_BOT_TOKEN=xoxb-hook\nSLACK_CHANNEL=CHOOK\n")
      app_root.join('.env').chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')
      ENV.delete('CODEX_NOTIFY_USER_NAME')

      original = HookConfig.method(:app_root)
      Dir.mktmpdir do |cwd|
        Pathname(cwd).join('.env').write("CODEX_NOTIFY_USER_NAME=cwd-user\n")
        Pathname(cwd).join('.env').chmod(0o600)

        Dir.chdir(cwd) do
          with_silenced_warnings do
            HookConfig.singleton_class.send(:define_method, :app_root) { app_root }
          end

          args = HookConfig.parse_args([], stderr: StringIO.new)
          assert_equal 'xoxb-hook', args.token
          assert_equal 'CHOOK', args.channel
          assert_equal 'cwd-user', args.user_name
        end
      end
    ensure
      with_silenced_warnings do
        HookConfig.singleton_class.send(:define_method, :app_root, original)
      end
    end
  end

  def test_system_user_name_prefers_environment_user_over_login_name
    ENV['USER'] = 'koichiro'
    ENV.delete('USERNAME')

    original = Etc.method(:getlogin)
    with_silenced_warnings do
      Etc.singleton_class.send(:define_method, :getlogin) { 'root' }
    end

    assert_equal 'koichiro', HookConfig.system_user_name
  ensure
    with_silenced_warnings do
      Etc.singleton_class.send(:define_method, :getlogin, original)
    end
  end

  def test_parse_args_defaults_to_normal_mode
    ENV.delete('CODEX_NOTIFY_MODE')

    assert_equal 'normal', HookConfig.parse_args(['--env-file', 'missing.env']).mode
  end

  def test_parse_args_uses_mode_from_environment
    ENV['CODEX_NOTIFY_MODE'] = 'debug'

    assert_equal 'debug', HookConfig.parse_args(['--env-file', 'missing.env']).mode
  end

  def test_parse_args_prefers_cli_mode_over_environment
    ENV['CODEX_NOTIFY_MODE'] = 'normal'

    assert_equal 'debug', HookConfig.parse_args(['--env-file', 'missing.env', '--mode', 'debug']).mode
  end

  def test_parse_args_rejects_invalid_environment_mode
    ENV['CODEX_NOTIFY_MODE'] = 'verbose'

    assert_raises(HookConfig::Error) { HookConfig.parse_args(['--env-file', 'missing.env']) }
  end

  def test_parse_args_warns_when_cli_token_is_used
    stderr = StringIO.new

    args = HookConfig.parse_args(['--env-file', 'missing.env', '--token', 'xoxb-cli'], stderr:)

    assert_equal 'xoxb-cli', args.token
    assert_includes stderr.string, '--token is deprecated'
  end

  def test_named_destination_normalizes_name_and_falls_back_to_default_token
    with_tmpdir do |dir|
      clear_hook_environment
      env_file = write_env(
        dir.join('profiles.env'),
        "SLACK_BOT_TOKEN=xoxb-default\nSLACK_CHANNEL__PROJECT_A=CPROJECT\n"
      )

      args = HookConfig.parse_args(['--env-file', env_file.to_s, '--destination', 'project_a'])

      assert_equal 'PROJECT_A', args.destination
      assert_equal 'xoxb-default', args.token
      assert_equal 'CPROJECT', args.channel
    end
  end

  def test_repository_selects_a_named_destination_from_xdg_config
    with_tmpdir do |xdg_home|
      with_tmpdir do |repository|
        clear_hook_environment
        ENV['XDG_CONFIG_HOME'] = xdg_home.to_s
        config_file = xdg_home.join('codex-notify/config.yml')
        config_file.dirname.mkpath
        config_file.write(
          "env_policy: restricted\ndefault_destination:\n  token: xoxb-default\n" \
          "destinations:\n  PROJECT_A:\n    channel: CPROJECT\n"
        )
        config_file.chmod(0o600)
        write_env(repository.join('.env'), "CODEX_NOTIFY_DESTINATION=PROJECT_A\n")

        args = Dir.chdir(repository) { HookConfig.parse_args }

        assert_equal 'PROJECT_A', args.destination
        assert_equal 'xoxb-default', args.token
        assert_equal 'CPROJECT', args.channel
      end
    end
  end

  def test_named_destination_prefers_profile_token_and_cli_values
    with_tmpdir do |dir|
      clear_hook_environment
      env_file = write_env(
        dir.join('profiles.env'),
        "SLACK_BOT_TOKEN=xoxb-default\nSLACK_BOT_TOKEN__PROJECT_A=xoxb-profile\n" \
          "SLACK_CHANNEL__PROJECT_A=CPROJECT\n"
      )

      profile = HookConfig.parse_args(['--env-file', env_file.to_s, '--destination', 'PROJECT_A'])
      cli = HookConfig.parse_args([
                                   '--env-file', env_file.to_s,
                                   '--destination', 'PROJECT_A',
                                   '--token', 'xoxb-cli',
                                   '--channel', 'CCLI'
                                 ], stderr: StringIO.new)

      assert_equal 'xoxb-profile', profile.token
      assert_equal 'CPROJECT', profile.channel
      assert_equal 'xoxb-cli', cli.token
      assert_equal 'CCLI', cli.channel
    end
  end

  def test_cli_destination_overrides_process_and_env_file_destinations
    with_tmpdir do |dir|
      clear_hook_environment
      ENV['CODEX_NOTIFY_DESTINATION'] = 'PROCESS'
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-process'
      ENV['SLACK_CHANNEL__CLI'] = 'CCLI'
      ENV['SLACK_CHANNEL__PROCESS'] = 'CPROCESS'
      env_file = write_env(
        dir.join('profiles.env'),
        "CODEX_NOTIFY_DESTINATION=FILE\nSLACK_CHANNEL__FILE=CFILE\n"
      )

      args = HookConfig.parse_args(['--env-file', env_file.to_s, '--destination', 'CLI'])

      assert_equal 'CLI', args.destination
      assert_equal 'CCLI', args.channel
    end
  end

  def test_process_destination_overrides_env_file_destination
    with_tmpdir do |dir|
      clear_hook_environment
      ENV['CODEX_NOTIFY_DESTINATION'] = 'PROCESS'
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-process'
      ENV['SLACK_CHANNEL__PROCESS'] = 'CPROCESS'
      env_file = write_env(
        dir.join('profiles.env'),
        "CODEX_NOTIFY_DESTINATION=FILE\nSLACK_CHANNEL__FILE=CFILE\n"
      )

      args = HookConfig.parse_args(['--env-file', env_file.to_s])

      assert_equal 'PROCESS', args.destination
      assert_equal 'CPROCESS', args.channel
    end
  end

  def test_named_destination_requires_a_trusted_profile_channel
    with_tmpdir do |dir|
      clear_hook_environment
      env_file = write_env(dir.join('profiles.env'), "SLACK_BOT_TOKEN=xoxb-default\n")

      error = assert_raises(HookConfig::Error) do
        HookConfig.parse_args([
                               '--env-file', env_file.to_s,
                               '--destination', 'UNKNOWN',
                               '--channel', 'CCLI'
                             ])
      end

      assert_includes error.message, 'missing SLACK_CHANNEL__UNKNOWN'
      refute_includes error.message, 'xoxb-default'
    end
  end

  def test_named_destination_requires_a_token_after_fallback
    with_tmpdir do |dir|
      clear_hook_environment
      env_file = write_env(dir.join('profiles.env'), "SLACK_CHANNEL__PROJECT_A=CPROJECT\n")

      error = assert_raises(HookConfig::Error) do
        HookConfig.parse_args(['--env-file', env_file.to_s, '--destination', 'PROJECT_A'])
      end

      assert_includes error.message, 'has no Slack bot token'
    end
  end

  def test_named_destination_rejects_unsafe_names_without_echoing_them
    clear_hook_environment

    error = assert_raises(HookConfig::Error) do
      HookConfig.parse_args(['--env-file', 'missing.env', '--destination', 'project-a'])
    end

    assert_includes error.message, 'only A-Z, 0-9, and _'
    refute_includes error.message, 'project-a'
  end

  def test_repository_profile_definitions_are_ignored
    with_tmpdir do |tool_root|
      with_tmpdir do |repository|
        clear_hook_environment
        write_env(tool_root.join('.env'), "SLACK_BOT_TOKEN=xoxb-trusted\n")
        write_env(
          repository.join('.env'),
          "CODEX_NOTIFY_DESTINATION=PROJECT_A\nSLACK_CHANNEL__PROJECT_A=CUNTRUSTED\n"
        )
        stderr = StringIO.new

        with_app_root(tool_root) do
          Dir.chdir(repository) do
            error = assert_raises(HookConfig::Error) { HookConfig.parse_args([], stderr:) }
            assert_includes error.message, 'missing SLACK_CHANNEL__PROJECT_A'
          end
        end

        assert_includes stderr.string, 'ignored SLACK_CHANNEL__PROJECT_A'
        refute_includes stderr.string, 'CUNTRUSTED'
      end
    end
  end

  def test_legacy_policy_uses_repository_credentials_with_a_deprecation_warning
    with_tmpdir do |tool_root|
      with_tmpdir do |repository|
        clear_hook_environment
        write_env(tool_root.join('.env'), "SLACK_BOT_TOKEN=xoxb-tool\nSLACK_CHANNEL=CTOOL\n")
        write_env(repository.join('.env'), "SLACK_BOT_TOKEN=xoxb-repository\nSLACK_CHANNEL=CREPOSITORY\n")
        stderr = StringIO.new

        args = with_app_root(tool_root) do
          Dir.chdir(repository) { HookConfig.parse_args([], stderr:) }
        end

        assert_equal 'xoxb-repository', args.token
        assert_equal 'CREPOSITORY', args.channel
        assert_includes stderr.string, 'are deprecated'
        assert_includes stderr.string, 'SLACK_BOT_TOKEN and SLACK_CHANNEL'
        refute_includes stderr.string, 'xoxb-repository'
      end
    end
  end

  def test_process_environment_overrides_repository_credentials_without_warning
    with_tmpdir do |tool_root|
      with_tmpdir do |repository|
        clear_hook_environment
        ENV['SLACK_BOT_TOKEN'] = 'xoxb-process'
        ENV['SLACK_CHANNEL'] = 'CPROCESS'
        write_env(repository.join('.env'), "SLACK_BOT_TOKEN=xoxb-repository\nSLACK_CHANNEL=CREPOSITORY\n")
        stderr = StringIO.new

        args = with_app_root(tool_root) do
          Dir.chdir(repository) { HookConfig.parse_args([], stderr:) }
        end

        assert_equal 'xoxb-process', args.token
        assert_equal 'CPROCESS', args.channel
        refute_includes stderr.string, 'are deprecated'
      end
    end
  end

  def test_restricted_policy_filters_repository_credentials_but_keeps_allowed_settings
    with_tmpdir do |tool_root|
      with_tmpdir do |repository|
        clear_hook_environment
        ENV['CODEX_NOTIFY_ENV_POLICY'] = 'restricted'
        write_env(
          tool_root.join('.env'),
          "SLACK_BOT_TOKEN=xoxb-trusted\nSLACK_CHANNEL__PROJECT_A=CTRUSTED\n"
        )
        write_env(
          repository.join('.env'),
          "CODEX_NOTIFY_DESTINATION=PROJECT_A\nCODEX_NOTIFY_TITLE=Repository title\n" \
            "SLACK_BOT_TOKEN=xoxb-untrusted\nSLACK_CHANNEL=CUNTRUSTED\n"
        )
        stderr = StringIO.new

        args = with_app_root(tool_root) do
          Dir.chdir(repository) { HookConfig.parse_args([], stderr:) }
        end

        assert_equal 'PROJECT_A', args.destination
        assert_equal 'xoxb-trusted', args.token
        assert_equal 'CTRUSTED', args.channel
        assert_equal 'Repository title', args.title
        assert_includes stderr.string, 'under the restricted policy'
        refute_includes stderr.string, 'xoxb-untrusted'
      end
    end
  end

  def test_explicit_env_file_may_supply_credentials_under_restricted_policy
    with_tmpdir do |dir|
      clear_hook_environment
      ENV['CODEX_NOTIFY_ENV_POLICY'] = 'restricted'
      env_file = write_env(dir.join('intentional.env'), "SLACK_BOT_TOKEN=xoxb-explicit\nSLACK_CHANNEL=CEXPLICIT\n")

      args = HookConfig.parse_args(['--env-file', env_file.to_s])

      assert_equal 'xoxb-explicit', args.token
      assert_equal 'CEXPLICIT', args.channel
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

  def clear_hook_environment
    ENV.keys.grep(/\A(?:SLACK_|CODEX_NOTIFY_|CODEX_HOOK_EVENT)/).each { |key| ENV.delete(key) }
  end

  def write_env(path, content)
    path.write(content)
    path.chmod(0o600)
    path
  end

  def with_app_root(path)
    original = HookConfig.method(:app_root)
    with_silenced_warnings do
      HookConfig.singleton_class.send(:define_method, :app_root) { path }
    end
    yield
  ensure
    with_silenced_warnings do
      HookConfig.singleton_class.send(:define_method, :app_root, original)
    end
  end
end
