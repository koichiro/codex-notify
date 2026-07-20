# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyTrustedConfigLoaderTest < Minitest::Test
  Loader = CodexNotify::TrustedConfigLoader

  def test_uses_xdg_config_home_without_a_version_key
    with_tmpdir do |xdg_home|
      path = write_config(
        xdg_home.join('codex-notify/config.yml'),
        <<~YAML
          env_policy: restricted
          default_destination:
            token: xoxb-default
            channel: CDEFAULT
          destinations:
            project_a:
              channel: CPROJECT
        YAML
      )

      files = Loader.new(environment: { 'XDG_CONFIG_HOME' => xdg_home.to_s }).load

      assert_equal [path], files.map(&:path)
      assert_equal :config, files.first.kind
      assert_equal 'restricted', files.first.values['CODEX_NOTIFY_ENV_POLICY']
      assert_equal 'CPROJECT', files.first.values['SLACK_CHANNEL__PROJECT_A']
    end
  end

  def test_falls_back_to_home_dot_config
    with_tmpdir do |home|
      path = write_config(home.join('.config/codex-notify/config.yml'), "default_destination:\n  channel: CHOME\n")

      files = Loader.new(environment: {}, home: home).load

      assert_equal [path], files.map(&:path)
    end
  end

  def test_explicit_config_precedes_default_config
    with_tmpdir do |dir|
      default = write_config(dir.join('xdg/codex-notify/config.yml'), "default_destination:\n  channel: CDEFAULT\n")
      explicit = write_config(dir.join('explicit.yml'), "default_destination:\n  channel: CEXPLICIT\n")

      files = Loader.new(environment: { 'XDG_CONFIG_HOME' => dir.join('xdg').to_s }).load(explicit_path: explicit)

      assert_equal %i[config_explicit config], files.map(&:kind)
      assert_equal [explicit, default], files.map(&:path)
    end
  end

  def test_rejects_version_and_unknown_keys
    with_tmpdir do |dir|
      path = write_config(dir.join('config.yml'), "version: 1\n")

      error = assert_raises(Loader::Error) do
        Loader.new(environment: { 'XDG_CONFIG_HOME' => dir.join('missing').to_s }).load(explicit_path: path)
      end

      assert_includes error.message, 'unknown keys'
    end
  end

  def test_rejects_aliases_and_does_not_echo_secret_values
    with_tmpdir do |dir|
      path = write_config(
        dir.join('config.yml'),
        "default_destination: &destination\n  token: xoxb-sensitive\n  channel: CDEFAULT\ncopy: *destination\n"
      )

      error = assert_raises(Loader::Error) do
        Loader.new(environment: { 'XDG_CONFIG_HOME' => dir.join('missing').to_s }).load(explicit_path: path)
      end

      assert_includes error.message, 'not valid safe YAML'
      refute_includes error.message, 'xoxb-sensitive'
    end
  end

  def test_validates_destinations_and_normalized_duplicates
    with_tmpdir do |dir|
      missing_channel = write_config(dir.join('missing.yml'), "destinations:\n  PROJECT_A:\n    token: xoxb-token\n")
      duplicate = write_config(
        dir.join('duplicate.yml'),
        "destinations:\n  project_a:\n    channel: CONE\n  PROJECT_A:\n    channel: CTWO\n"
      )
      loader = Loader.new(environment: { 'XDG_CONFIG_HOME' => dir.join('none').to_s })

      error = assert_raises(Loader::Error) { loader.load(explicit_path: missing_channel) }
      assert_includes error.message, 'must define channel'
      error = assert_raises(Loader::Error) { loader.load(explicit_path: duplicate) }
      assert_includes error.message, 'duplicated after normalization'
    end
  end

  def test_warns_about_insecure_permissions_without_showing_values
    with_tmpdir do |dir|
      path = write_config(dir.join('config.yml'), "default_destination:\n  token: xoxb-sensitive\n", mode: 0o644)
      stderr = StringIO.new

      Loader.new(environment: { 'XDG_CONFIG_HOME' => dir.join('none').to_s }, stderr:).load(explicit_path: path)

      assert_includes stderr.string, 'config file'
      assert_includes stderr.string, 'permissions 0644'
      refute_includes stderr.string, 'xoxb-sensitive'
    end
  end

  def test_rejects_relative_xdg_config_home
    error = assert_raises(Loader::Error) do
      Loader.new(environment: { 'XDG_CONFIG_HOME' => 'relative' }).load
    end

    assert_includes error.message, 'must be an absolute path'
  end

  def test_does_not_discover_config_from_the_current_directory
    with_tmpdir do |cwd|
      write_config(cwd.join('config.yml'), "default_destination:\n  token: xoxb-cwd\n")
      files = Dir.chdir(cwd) do
        Loader.new(environment: { 'XDG_CONFIG_HOME' => cwd.join('missing').to_s }).load
      end

      assert_empty files
    end
  end

  private

  def with_tmpdir
    Dir.mktmpdir { |dir| yield Pathname(dir) }
  end

  def write_config(path, contents, mode: 0o600)
    path.dirname.mkpath
    path.write(contents)
    path.chmod(mode)
    path
  end
end
