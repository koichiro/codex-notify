# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'yaml'
require_relative 'test_helper'

class CodexNotifyConfigMigratorTest < Minitest::Test
  ConfigMigrator = CodexNotify::ConfigMigrator

  def test_migrates_tool_root_env_to_xdg_yaml_without_a_version
    with_tmpdir do |app_root|
      with_tmpdir do |xdg_home|
        source = write_env(
          app_root.join('.env'),
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
          app_root:,
          environment: { 'XDG_CONFIG_HOME' => xdg_home.to_s },
          stdout:,
          stderr:
        )

        assert_equal 0, migrator.run(env_path: '.env', env_explicit: false)

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
      source = write_env(dir.join('legacy.env'), "SLACK_BOT_TOKEN=xoxb-token\nSLACK_CHANNEL=CEXPLICIT\n")
      target = dir.join('output/config.yml')
      migrator = ConfigMigrator.new(
        app_root: dir.join('unused'),
        environment: { 'XDG_CONFIG_HOME' => dir.join('unused-xdg').to_s },
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      migrator.run(env_path: source, env_explicit: true, config_path: target)

      assert_equal 'CEXPLICIT', YAML.safe_load_file(target.to_s).dig('default_destination', 'channel')
    end
  end

  def test_dry_run_validates_without_creating_files_or_directories
    with_tmpdir do |dir|
      source = write_env(
        dir.join('legacy.env'),
        "CODEX_NOTIFY_ENV_POLICY=restricted\nSLACK_BOT_TOKEN=xoxb-sensitive\n" \
        "SLACK_CHANNEL=CSECRET\nSLACK_CHANNEL__PROJECT_A=CPROJECT\n"
      )
      target = dir.join('not-created/config.yml')
      stdout = StringIO.new
      migrator = ConfigMigrator.new(app_root: dir, stdout:, stderr: StringIO.new)

      assert_equal 0, migrator.run(env_path: source, env_explicit: true, config_path: target, dry_run: true)

      refute target.exist?
      refute target.dirname.exist?
      assert_includes stdout.string, 'Migration check passed'
      assert_includes stdout.string, '1 named destination(s)'
      assert_includes stdout.string, 'No files were created or modified'
      refute_includes stdout.string, 'xoxb-sensitive'
      refute_includes stdout.string, 'CSECRET'
      refute_includes stdout.string, 'CPROJECT'
    end
  end

  def test_refuses_to_overwrite_an_existing_config
    with_tmpdir do |dir|
      source = write_env(dir.join('.env'), "SLACK_BOT_TOKEN=xoxb-sensitive\n")
      target = dir.join('config.yml')
      target.write("existing: true\n")
      target.chmod(0o600)
      migrator = new_migrator(dir)

      error = assert_raises(ConfigMigrator::Error) do
        migrator.run(env_path: source, env_explicit: true, config_path: target)
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
        new_migrator(dir).run(env_path: source, env_explicit: true, config_path: target)
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
        new_migrator(dir).run(
          env_path: source,
          env_explicit: true,
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
        new_migrator(dir).run(
          env_path: source,
          env_explicit: true,
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
      migrator = ConfigMigrator.new(app_root: dir, stdout: StringIO.new, stderr:)

      migrator.run(env_path: source, env_explicit: true, config_path: dir.join('config.yml'))

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

  def new_migrator(app_root)
    ConfigMigrator.new(app_root:, stdout: StringIO.new, stderr: StringIO.new)
  end
end
