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

          args = HookConfig.parse_args([])
          assert_equal 'xoxb-hook', args.token
          assert_equal 'CHOOK', args.channel
          assert_equal 'hook-user', args.user_name
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

          args = HookConfig.parse_args([])
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

    assert_raises(OptionParser::InvalidArgument) { HookConfig.parse_args(['--env-file', 'missing.env']) }
  end

  def test_parse_args_warns_when_cli_token_is_used
    stderr = StringIO.new

    args = HookConfig.parse_args(['--env-file', 'missing.env', '--token', 'xoxb-cli'], stderr:)

    assert_equal 'xoxb-cli', args.token
    assert_includes stderr.string, '--token is deprecated'
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
