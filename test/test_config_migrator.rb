# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'yaml'
require_relative 'test_helper'

class CodexNotifyConfigMigratorTest < Minitest::Test
  ConfigMigrator = CodexNotify::ConfigMigrator

  def test_migrates_checkout_root_env_to_xdg_yaml_without_a_version
    with_tmpdir do |checkout_root|
      with_tmpdir do |xdg_home|
        source = write_env(
          checkout_root.join('.env'),
          <<~ENV
            CODEX_NOTIFY_ENV_POLICY=restricted
            SLACK_BOT_TOKEN=xoxb-sensitive-default
            SLACK_CHANNEL=CDEFAULT
            SLACK_BOT_TOKEN__project_a=xoxb-sensitive-project
            SLACK_CHANNEL__project_a=CPROJECT
            SLACK_CHANNEL__PROJECT_B=CPROJECTB
            CODEX_NOTIFY_MODE=debug
          ENV
        )
        stdout = StringIO.new
        stderr = StringIO.new
        migrator = ConfigMigrator.new(
          legacy_checkout_root: checkout_root,
          environment: { 'XDG_CONFIG_HOME' => xdg_home.to_s },
          stdout:,
          stderr:
        )

        assert_equal 0, migrator.run

        target = xdg_home.join('codex-notify/config.yml')
        document = YAML.safe_load_file(target.to_s, aliases: false)
        loaded = CodexNotify::TrustedConfigLoader.new(
          environment: { 'XDG_CONFIG_HOME' => xdg_home.to_s },
          stderr: StringIO.new
        ).load(explicit_path: target)
        assert_equal(
          {
            'env_policy' => 'restricted',
            'default_destination' => {
              'token' => 'xoxb-sensitive-default',
              'channel' => 'CDEFAULT'
            },
            'destinations' => {
              'PROJECT_A' => {
                'token' => 'xoxb-sensitive-project',
                'channel' => 'CPROJECT'
              },
              'PROJECT_B' => { 'channel' => 'CPROJECTB' }
            }
          },
          document
        )
        refute document.key?('version')
        assert_equal 'CPROJECT', loaded.first.values['SLACK_CHANNEL__PROJECT_A']
        assert_equal 0o600, target.stat.mode & 0o777
        assert source.exist?
        assert_includes stdout.string, target.to_s
        assert_includes stdout.string, 'remove migrated secrets'
        refute_includes stdout.string, 'xoxb-sensitive'
        refute_includes stderr.string, 'xoxb-sensitive'
      end
    end
  end

  def test_explicit_paths_override_default_source_and_target
    with_tmpdir do |dir|
      write_env(dir.join('checkout/.env'), "SLACK_CHANNEL=CCHECKOUT\n")
      source = write_env(dir.join('legacy.env'), "SLACK_BOT_TOKEN=xoxb-token\nSLACK_CHANNEL=CEXPLICIT\n")
      target = dir.join('output/config.yml')
      migrator = ConfigMigrator.new(
        legacy_checkout_root: dir.join('checkout'),
        environment: { 'XDG_CONFIG_HOME' => dir.join('unused-xdg').to_s },
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      Dir.chdir(dir.join('checkout')) do
        migrator.run(env_path: source, config_path: target)
      end

      assert_equal 'CEXPLICIT', YAML.safe_load_file(target.to_s).dig('default_destination', 'channel')
    end
  end

  def test_requires_an_explicit_source_outside_a_checkout
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "SLACK_BOT_TOKEN=xoxb-must-not-load\n")
      migrator = ConfigMigrator.new(
        environment: { 'XDG_CONFIG_HOME' => dir.join('xdg').to_s },
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      error = Dir.chdir(dir) { assert_raises(ConfigMigrator::Error) { migrator.run } }

      assert_includes error.message, 'requires --env-file PATH'
      refute_includes error.message, 'xoxb-must-not-load'
      assert source.exist?
      refute dir.join('xdg/codex-notify/config.yml').exist?
    end
  end

  def test_explicit_relative_source_is_resolved_from_the_current_directory
    with_tmpdir do |dir|
      write_env(dir.join('legacy.env'), "SLACK_CHANNEL=CRELATIVE\n")
      target = dir.join('config.yml')

      Dir.chdir(dir) { new_migrator.run(env_path: 'legacy.env', config_path: target) }

      assert_equal 'CRELATIVE', YAML.safe_load_file(target.to_s).dig('default_destination', 'channel')
    end
  end

  def test_invalid_xdg_home_is_reported_as_a_migration_error
    with_tmpdir do |dir|
      source = write_env(dir.join('legacy.env'), "SLACK_CHANNEL=CVALID\n")
      migrator = ConfigMigrator.new(
        environment: { 'XDG_CONFIG_HOME' => 'relative' },
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      error = assert_raises(ConfigMigrator::Error) { migrator.run(env_path: source) }

      assert_includes error.message, 'XDG_CONFIG_HOME must be an absolute path'
    end
  end

  def test_reports_a_missing_checkout_source_without_creating_output
    with_tmpdir do |checkout_root|
      target = checkout_root.join('config.yml')
      migrator = ConfigMigrator.new(
        legacy_checkout_root: checkout_root,
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      error = assert_raises(ConfigMigrator::Error) { migrator.run(config_path: target) }

      assert_includes error.message, 'legacy env file does not exist'
      assert_includes error.message, checkout_root.join('.env').to_s
      refute target.exist?
    end
  end

  def test_rejects_a_directory_as_an_explicit_source
    with_tmpdir do |dir|
      error = assert_raises(ConfigMigrator::Error) do
        new_migrator.run(env_path: dir, config_path: dir.join('config.yml'))
      end

      assert_includes error.message, 'legacy env path is not a file'
      refute dir.join('config.yml').exist?
    end
  end

  def test_refuses_to_overwrite_an_existing_config
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "SLACK_BOT_TOKEN=xoxb-sensitive\n")
      target = dir.join('config.yml')
      target.write("existing: true\n")
      target.chmod(0o600)
      migrator = new_migrator

      error = assert_raises(ConfigMigrator::Error) do
        migrator.run(env_path: source, config_path: target)
      end

      assert_includes error.message, 'already exists'
      assert_equal "existing: true\n", target.read
      refute_includes error.message, 'xoxb-sensitive'
    end
  end

  def test_rejects_an_incomplete_profile_without_creating_output
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "SLACK_BOT_TOKEN__PROJECT_A=xoxb-sensitive\n")
      target = dir.join('config.yml')

      error = assert_raises(ConfigMigrator::Error) do
        new_migrator.run(env_path: source, config_path: target)
      end

      assert_includes error.message, 'must define channel'
      refute_includes error.message, 'xoxb-sensitive'
      refute target.exist?
    end
  end

  def test_rejects_normalized_profile_name_collisions
    with_tmpdir do |dir|
      source = write_env(
        dir.join('.env'),
        "SLACK_CHANNEL__project_a=CONE\nSLACK_CHANNEL__PROJECT_A=CTWO\n"
      )

      error = assert_raises(ConfigMigrator::Error) do
        new_migrator.run(
          env_path: source,
          config_path: dir.join('config.yml')
        )
      end

      assert_includes error.message, 'duplicated after normalization'
    end
  end

  def test_rejects_env_without_trusted_settings
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "CODEX_NOTIFY_MODE=debug\n")

      error = assert_raises(ConfigMigrator::Error) do
        new_migrator.run(
          env_path: source,
          config_path: dir.join('config.yml')
        )
      end

      assert_includes error.message, 'no trusted settings to migrate'
    end
  end

  def test_permission_warning_does_not_expose_values
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "SLACK_BOT_TOKEN=xoxb-sensitive\n", mode: 0o644)
      stderr = StringIO.new
      migrator = ConfigMigrator.new(stdout: StringIO.new, stderr:)

      migrator.run(env_path: source, config_path: dir.join('config.yml'))

      assert_includes stderr.string, 'permissions 0644'
      refute_includes stderr.string, 'xoxb-sensitive'
    end
  end

  private

  def with_tmpdir
    Dir.mktmpdir { |dir| yield Pathname(dir) }
  end

  def write_env(path, contents, mode: 0o600)
    path.dirname.mkpath
    path.write(contents)
    path.chmod(mode)
    path
  end

  def new_migrator
    ConfigMigrator.new(stdout: StringIO.new, stderr: StringIO.new)
  end
end
