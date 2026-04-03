# frozen_string_literal: true

require 'tmpdir'
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
      ENV['SLACK_BOT_TOKEN'] = 'existing'

      Config.load_env_file(env_file.to_s)

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

      args = Config.parse_args(['--env-file', env_file.to_s])

      assert_equal 'xoxb-from-env', args.token
      assert_equal 'CENV', args.channel
      assert_equal 'alice', args.user_name
    end
  end

  def test_load_env_file_falls_back_to_app_root_for_relative_path
    with_tmpdir do |dir|
      env_file = dir.join('.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-app-root\nSLACK_CHANNEL=CROOT\n")
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

  def test_parse_args_prefers_cli_user_name_over_env
    ENV['CODEX_NOTIFY_USER_NAME'] = 'env-user'

    args = Config.parse_args(['--user-name', 'cli-user'])

    assert_equal 'cli-user', args.user_name
  end

  def test_parse_args_uses_system_user_name_when_no_override_is_present
    ENV.delete('CODEX_NOTIFY_USER_NAME')

    original = Config.method(:system_user_name)
    with_silenced_warnings do
      Config.singleton_class.send(:define_method, :system_user_name) { 'local-user' }
    end
    begin
      args = Config.parse_args([])
      assert_equal 'local-user', args.user_name
    ensure
      with_silenced_warnings do
        Config.singleton_class.send(:define_method, :system_user_name, original)
      end
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
