# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require_relative 'test_helper'

class CodexNotifyConfigTest < Minitest::Test
  Config = CodexNotify::Config

  def setup
    @env_backup = ENV.to_h
  end

  def teardown
    ENV.replace(@env_backup)
  end

  def test_getenv_any_returns_first_match
    ENV.delete('FIRST')
    ENV['SECOND'] = 'value'
    assert_equal 'value', Config.getenv_any(%w[FIRST SECOND])
  end

  def test_load_env_file_sets_values
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-test\nSLACK_CHANNEL=C123\n")
      env_file.chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      Config.load_env_file(env_file.to_s)

      assert_equal 'xoxb-test', ENV['SLACK_BOT_TOKEN']
      assert_equal 'C123', ENV['SLACK_CHANNEL']
    end
  end

  def test_load_env_file_does_not_override_existing_value
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-test\n")
      env_file.chmod(0o600)
      ENV['SLACK_BOT_TOKEN'] = 'existing'

      Config.load_env_file(env_file.to_s)

      assert_equal 'existing', ENV['SLACK_BOT_TOKEN']
    end
  end

  def test_parse_args_uses_env_file_defaults
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-from-env\nSLACK_CHANNEL=CENV\nCODEX_NOTIFY_USER_NAME=alice\n")
      env_file.chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')
      ENV.delete('CODEX_NOTIFY_USER_NAME')

      args = Config.parse_args(['--env-file', env_file.to_s])

      assert_equal 'xoxb-from-env', args.token
      assert_equal 'CENV', args.channel
      assert_equal 'alice', args.user_name
    end
  end

  def test_parse_args_uses_xdg_default_destination
    with_tmpdir do |xdg_home|
      config_file = xdg_home.join('codex-notify/config.yml')
      config_file.dirname.mkpath
      config_file.write("default_destination:\n  token: xoxb-xdg\n  channel: CXDG\n")
      config_file.chmod(0o600)
      ENV['XDG_CONFIG_HOME'] = xdg_home.to_s
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      args = Config.parse_args(['--env-file', 'missing.env'])

      assert_equal 'xoxb-xdg', args.token
      assert_equal 'CXDG', args.channel
    end
  end

  def test_process_environment_and_explicit_config_precedence
    with_tmpdir do |dir|
      xdg_file = dir.join('xdg/codex-notify/config.yml')
      xdg_file.dirname.mkpath
      xdg_file.write("default_destination:\n  token: xoxb-xdg\n  channel: CXDG\n")
      xdg_file.chmod(0o600)
      explicit = dir.join('explicit.yml')
      explicit.write("default_destination:\n  token: xoxb-explicit\n  channel: CEXPLICIT\n")
      explicit.chmod(0o600)
      ENV['XDG_CONFIG_HOME'] = dir.join('xdg').to_s
      ENV['SLACK_BOT_TOKEN'] = 'xoxb-process'

      args = Config.parse_args(['--env-file', 'missing.env', '--config', explicit.to_s])

      assert_equal 'xoxb-process', args.token
      assert_equal 'CEXPLICIT', args.channel
    end
  end

  def test_explicit_env_file_precedes_default_xdg_config
    with_tmpdir do |dir|
      xdg_file = dir.join('xdg/codex-notify/config.yml')
      xdg_file.dirname.mkpath
      xdg_file.write("default_destination:\n  token: xoxb-xdg\n  channel: CXDG\n")
      xdg_file.chmod(0o600)
      env_file = dir.join('explicit.env')
      env_file.write("SLACK_CHANNEL=CENV\n")
      env_file.chmod(0o600)
      ENV['XDG_CONFIG_HOME'] = dir.join('xdg').to_s
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      args = Config.parse_args(['--env-file', env_file.to_s])

      assert_equal 'xoxb-xdg', args.token
      assert_equal 'CENV', args.channel
    end
  end

  def test_missing_explicit_config_is_a_configuration_error
    with_tmpdir do |dir|
      error = assert_raises(Config::Error) do
        Config.parse_args(['--env-file', 'missing.env', '--config', dir.join('missing.yml').to_s])
      end

      assert_includes error.message, 'config file does not exist'
    end
  end

  def test_parse_args_uses_prompt_and_title_from_environment
    ENV['CODEX_PROMPT'] = 'Investigate failing tests'
    ENV['CODEX_NOTIFY_TITLE'] = 'Codex run: tests'

    args = Config.parse_args(['--env-file', 'missing.env'])

    assert_equal 'Investigate failing tests', args.prompt
    assert_equal 'Codex run: tests', args.title
  end

  def test_parse_args_prefers_cli_prompt_and_title_over_environment
    ENV['CODEX_PROMPT'] = 'environment prompt'
    ENV['CODEX_NOTIFY_TITLE'] = 'environment title'

    args = Config.parse_args([
                               '--env-file', 'missing.env',
                               '--prompt', 'CLI prompt',
                               '--title', 'CLI title'
                             ])

    assert_equal 'CLI prompt', args.prompt
    assert_equal 'CLI title', args.title
  end

  def test_load_env_file_falls_back_to_app_root_for_relative_path
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-app-root\nSLACK_CHANNEL=CROOT\n")
      env_file.chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      original = Config.method(:app_root)
      Dir.mktmpdir do |cwd|
        Dir.chdir(cwd) do
          with_silenced_warnings do
            Config.singleton_class.send(:define_method, :app_root) { dir }
          end

          Config.load_env_file('.env')
        end
      end
    ensure
      with_silenced_warnings do
        Config.singleton_class.send(:define_method, :app_root, original)
      end
    end

    assert_equal 'xoxb-app-root', ENV['SLACK_BOT_TOKEN']
    assert_equal 'CROOT', ENV['SLACK_CHANNEL']
  end

  def test_load_env_file_merges_cwd_and_app_root_relative_paths
    with_tmpdir do |app_root|
      app_root.join('.env').write("SLACK_BOT_TOKEN=xoxb-app-root\nSLACK_CHANNEL=CROOT\n")
      app_root.join('.env').chmod(0o600)
      ENV.delete('SLACK_BOT_TOKEN')
      ENV.delete('SLACK_CHANNEL')

      original = Config.method(:app_root)
      Dir.mktmpdir do |cwd|
        Pathname(cwd).join('.env').write("CODEX_NOTIFY_USER_NAME=cwd-user\n")
        Pathname(cwd).join('.env').chmod(0o600)

        Dir.chdir(cwd) do
          with_silenced_warnings do
            Config.singleton_class.send(:define_method, :app_root) { app_root }
          end

          stderr = StringIO.new
          args = Config.parse_args([], stderr:)
          assert_equal 'xoxb-app-root', args.token
          assert_equal 'CROOT', args.channel
          assert_equal 'cwd-user', args.user_name
          assert_includes stderr.string, 'legacy codex-notify env file'
          refute_includes stderr.string, 'xoxb-app-root'
        end
      end
    ensure
      with_silenced_warnings do
        Config.singleton_class.send(:define_method, :app_root, original)
      end
    end
  end

  def test_parse_args_prefers_cli_user_name_over_env
    ENV['CODEX_NOTIFY_USER_NAME'] = 'env-user'

    args = Config.parse_args(['--env-file', 'missing.env', '--user-name', 'cli-user'])

    assert_equal 'cli-user', args.user_name
  end

  def test_parse_args_warns_when_cli_token_is_used
    stderr = StringIO.new

    args = Config.parse_args(['--env-file', 'missing.env', '--token', 'xoxb-cli'], stderr:)

    assert_equal 'xoxb-cli', args.token
    assert_includes stderr.string, '--token is deprecated'
    assert_includes stderr.string, 'process lists and shell history'
  end

  def test_parse_args_warns_when_env_file_permissions_are_insecure
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-from-env\n")
      env_file.chmod(0o644)
      stderr = StringIO.new

      Config.parse_args(['--env-file', env_file.to_s], stderr:)

      assert_includes stderr.string, 'permissions 0644'
      assert_includes stderr.string, 'chmod 600'
    end
  end

  def test_parse_args_uses_system_user_name_when_no_override_is_present
    ENV.delete('CODEX_NOTIFY_USER_NAME')

    original = Config.method(:system_user_name)
    with_silenced_warnings do
      Config.singleton_class.send(:define_method, :system_user_name) { 'local-user' }
    end
    begin
      args = Config.parse_args(['--env-file', 'missing.env'])
      assert_equal 'local-user', args.user_name
    ensure
      with_silenced_warnings do
        Config.singleton_class.send(:define_method, :system_user_name, original)
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

    assert_equal 'koichiro', Config.system_user_name
  ensure
    with_silenced_warnings do
      Etc.singleton_class.send(:define_method, :getlogin, original)
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
