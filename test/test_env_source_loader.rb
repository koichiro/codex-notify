# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifyEnvSourceLoaderTest < Minitest::Test
  EnvSourceLoader = CodexNotify::EnvSourceLoader

  def test_load_discovers_and_classifies_sources_in_precedence_order
    with_tmpdir do |checkout_root|
      with_tmpdir do |repository|
        write_env(checkout_root.join('.env'), "VALUE=tool\nTOOL_ONLY=yes\n")
        write_env(repository.join('.env'), "VALUE=repository\n")
        loader = env_loader(legacy_checkout_root: checkout_root, environment: { 'VALUE' => 'process' })

        sources = Dir.chdir(repository) { loader.load }

        assert_equal %i[process repository tool], sources.map(&:kind)
        result = sources.lookup('VALUE')
        assert_equal 'process', result.value
        assert_equal :process, result.source.kind
        assert_equal 'yes', sources.lookup('TOOL_ONLY').value
      end
    end
  end

  def test_load_does_not_discover_an_implicit_library_root
    with_tmpdir do |installation_root|
      with_tmpdir do |repository|
        write_env(installation_root.join('.env'), "INSTALL_ONLY=must-not-load\n")
        write_env(repository.join('.env'), "REPOSITORY_ONLY=yes\n")

        loader = env_loader(environment: {})
        loader.define_singleton_method(:app_root) { installation_root }

        sources = Dir.chdir(repository) { loader.load }

        assert_equal %i[process repository], sources.map(&:kind)
        assert_equal 'yes', sources.lookup('REPOSITORY_ONLY').value
        assert_nil sources.lookup('INSTALL_ONLY')
      end
    end
  end

  def test_load_deduplicates_repository_and_checkout_paths
    with_tmpdir do |repository|
      write_env(repository.join('.env'), "VALUE=repository\n")
      loader = env_loader(legacy_checkout_root: repository, environment: {})

      sources = Dir.chdir(repository) { loader.load }

      assert_equal %i[process tool], sources.map(&:kind)
      assert_equal 'repository', sources.lookup('VALUE').value
    end
  end

  def test_explicit_env_file_is_trusted_and_does_not_modify_environment
    with_tmpdir do |dir|
      env_file = write_env(dir.join('intentional.env'), "SLACK_BOT_TOKEN=xoxb-explicit\n")
      environment = {}

      sources = env_loader(environment:).load(path: env_file, explicit: true)

      assert_equal %i[process explicit], sources.map(&:kind)
      assert_equal 'xoxb-explicit', sources.lookup('SLACK_BOT_TOKEN').value
      assert_empty environment
    end
  end

  def test_source_views_preserve_named_lookup_results_without_mutating_original
    repository = source(:repository, 'ALLOWED' => 'yes', 'SECRET' => 'hidden')
    tool = source(:tool, 'SECRET' => 'trusted')
    sources = EnvSourceLoader::SourceSet.new([repository, tool])

    trusted = sources.excluding_kind(:repository)
    restricted = sources.restrict_kind(:repository, keys: ['ALLOWED'])

    assert_equal :tool, trusted.lookup('SECRET').source.kind
    assert_equal 'trusted', restricted.lookup('SECRET').value
    assert_equal 'hidden', sources.lookup('SECRET').value
    assert_equal 'yes', restricted.lookup('ALLOWED').value
  end

  def test_lookup_ignores_empty_values
    sources = EnvSourceLoader::SourceSet.new([
      source(:process, 'VALUE' => ''),
      source(:tool, 'VALUE' => 'configured')
    ])

    result = sources.lookup('VALUE')

    assert_equal 'configured', result.value
    assert_equal :tool, result.source.kind
    assert_nil sources.lookup('MISSING')
  end

  def test_load_warns_about_insecure_permissions_without_showing_values
    with_tmpdir do |dir|
      env_file = dir.join('insecure.env')
      env_file.write("SLACK_BOT_TOKEN=xoxb-sensitive\n")
      env_file.chmod(0o644)
      stderr = StringIO.new

      env_loader(environment: {}, stderr:).load(path: env_file, explicit: true)

      assert_includes stderr.string, 'permissions 0644'
      refute_includes stderr.string, 'xoxb-sensitive'
    end
  end

  def test_load_wraps_file_errors_without_exposing_file_contents
    with_tmpdir do |dir|
      env_file = write_env(dir.join('unreadable.env'), "SECRET=sensitive-value\n")

      original_parse = Dotenv.method(:parse)
      with_silenced_warnings do
        Dotenv.singleton_class.send(:define_method, :parse) { |_path| raise Errno::EACCES }
      end
      error = begin
        assert_raises(EnvSourceLoader::Error) do
          env_loader(environment: {}).load(path: env_file, explicit: true)
        end
      ensure
        with_silenced_warnings do
          Dotenv.singleton_class.send(:define_method, :parse, original_parse)
        end
      end

      assert_includes error.message, env_file.to_s
      assert_includes error.message, 'Errno::EACCES'
      refute_includes error.message, 'sensitive-value'
    end
  end

  private

  def env_loader(environment:, stderr: $stderr, **options)
    config_loader = CodexNotify::TrustedConfigLoader.new(
      environment: { 'XDG_CONFIG_HOME' => TEST_XDG_CONFIG_HOME.to_s },
      stderr:
    )
    EnvSourceLoader.new(environment:, stderr:, config_loader:, **options)
  end

  def source(kind, values)
    EnvSourceLoader::Source.new(kind:, path: nil, values:)
  end

  def with_tmpdir
    Dir.mktmpdir { |dir| yield Pathname(dir) }
  end

  def with_silenced_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end

  def write_env(path, content)
    path.write(content)
    path.chmod(0o600)
    path
  end
end
