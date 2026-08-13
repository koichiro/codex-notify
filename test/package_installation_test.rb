# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'rbconfig'
require 'rubygems/package'
require 'tmpdir'

class PackageInstallationTest < Minitest::Test
  ROOT = Pathname(__dir__).join('..').expand_path.freeze
  FIXED_PACKAGE_FILES = %w[
    CHANGELOG.md
    LICENSE
    README.md
    bin/codex-notify
    bin/codex-notify-hook
  ].freeze
  FORBIDDEN_PACKAGE_ROOTS = %w[
    .bundle
    .codex
    .git
    .github
    pkg
    test
    vendor
  ].freeze
  FORBIDDEN_PACKAGE_NAMES = %w[.env .session].freeze

  def test_built_package_is_complete_and_runs_from_an_isolated_gem_home
    package_path = Pathname(ENV.fetch('CODEX_NOTIFY_PACKAGE_PATH')).expand_path
    assert package_path.file?, "expected built package at #{package_path}"

    package = Gem::Package.new(package_path.to_s)
    assert_package_contents(package)

    Dir.mktmpdir('codex-notify-package-verification') do |tmpdir|
      dir = Pathname(tmpdir)
      gem_home = install_package(package_path, dir)
      assert_installed_specs(gem_home, package.spec)

      run_dir = dir.join('run')
      run_dir.mkpath
      assert_installed_require(gem_home, dir, run_dir, package.spec)
      assert_installed_help(gem_home, dir, run_dir, 'codex-notify', 'Usage: codex-notify [options]')
      assert_installed_help(gem_home, dir, run_dir, 'codex-notify-hook', 'Usage: codex-notify-hook [options]')
      assert_installed_hook_errors(gem_home, dir, run_dir)
    end
  end

  private

  def assert_package_contents(package)
    expected = expected_package_files
    contents = package.contents.sort

    assert_equal 'codex-notify', package.spec.name
    assert_equal expected, package.spec.files.sort
    assert_equal expected, contents
    assert_equal %w[codex-notify codex-notify-hook], package.spec.executables.sort
    contents.each do |path|
      parts = Pathname(path).each_filename.to_a
      refute Pathname(path).absolute?, "package path must be relative: #{path}"
      refute_includes parts, '..'
      refute_includes FORBIDDEN_PACKAGE_ROOTS, parts.first
      assert_empty parts & FORBIDDEN_PACKAGE_NAMES, "forbidden package path: #{path}"
    end
  end

  def expected_package_files
    (Dir.chdir(ROOT) { Dir['lib/**/*.rb'] } + FIXED_PACKAGE_FILES).sort
  end

  def install_package(package_path, dir)
    repository = dir.join('gem-repository')
    repository.mkpath
    dotenv_spec = Gem::Specification.find_by_name('dotenv', '~> 3.2')
    dotenv_package = Pathname(dotenv_spec.cache_file)
    assert dotenv_package.file?, "expected cached gem at #{dotenv_package}"

    local_dotenv = repository.join(dotenv_package.basename)
    local_package = repository.join(package_path.basename)
    FileUtils.cp(dotenv_package, local_dotenv)
    FileUtils.cp(package_path, local_package)

    gem_home = dir.join('gem-home')
    stdout, stderr, status = Open3.capture3(
      isolated_environment(gem_home, dir),
      RbConfig.ruby,
      '-S',
      'gem',
      'install',
      '--local',
      '--no-document',
      local_dotenv.basename.to_s,
      local_package.basename.to_s,
      chdir: repository.to_s,
      unsetenv_others: true
    )

    assert status.success?, "local gem install failed:\n#{stdout}\n#{stderr}"
    gem_home
  end

  def assert_installed_specs(gem_home, package_spec)
    dotenv_spec = Gem::Specification.find_by_name('dotenv', '~> 3.2')
    installed = gem_home.join('specifications').glob('*.gemspec').map { |path| path.basename.to_s }.sort

    assert_equal [
      "codex-notify-#{package_spec.version}.gemspec",
      "dotenv-#{dotenv_spec.version}.gemspec"
    ], installed
  end

  def assert_installed_require(gem_home, dir, run_dir, package_spec)
    script = <<~'RUBY'
      require 'codex_notify'

      feature = $LOADED_FEATURES.find { |path| path.end_with?('/codex_notify.rb') }
      spec = Gem.loaded_specs.fetch('codex-notify')
      gem_home = File.realpath(ENV.fetch('GEM_HOME'))
      isolation_root = File.realpath(ENV.fetch('ISOLATION_ROOT'))
      source_root = File.realpath(ENV.fetch('SOURCE_ROOT'))
      installed_root = File.realpath(spec.full_gem_path)
      abort 'codex_notify was not loaded from its installed gem' unless feature&.start_with?(spec.full_gem_path)
      abort 'codex_notify was not loaded from GEM_HOME' unless installed_root.start_with?("#{gem_home}/")
      abort 'HOME is not isolated' unless File.realpath(File.dirname(ENV.fetch('HOME'))) == isolation_root
      unless File.realpath(File.dirname(ENV.fetch('XDG_CONFIG_HOME'))) == isolation_root
        abort 'XDG_CONFIG_HOME is not isolated'
      end
      %w[BUNDLE_GEMFILE RUBYLIB RUBYOPT].each do |name|
        abort "#{name} leaked into the installed-gem process" if ENV.key?(name)
      end
      abort 'source checkout is present on the load path' if $LOAD_PATH.any? do |path|
        File.expand_path(path).start_with?(source_root)
      end

      puts "#{CodexNotify::VERSION} #{Gem.loaded_specs.fetch('dotenv').version}"
    RUBY
    stdout, stderr, status = Open3.capture3(
      isolated_environment(gem_home, dir).merge(
        'ISOLATION_ROOT' => dir.realpath.to_s,
        'SOURCE_ROOT' => ROOT.realpath.to_s
      ),
      RbConfig.ruby,
      '-e',
      script,
      chdir: run_dir.to_s,
      unsetenv_others: true
    )

    dotenv_version = Gem::Specification.find_by_name('dotenv', '~> 3.2').version
    assert status.success?, "installed gem load failed:\n#{stdout}\n#{stderr}"
    assert_equal "#{package_spec.version} #{dotenv_version}\n", stdout
    assert_empty stderr
  end

  def assert_installed_help(gem_home, dir, run_dir, executable, usage)
    stdout, stderr, status = run_installed_executable(gem_home, dir, run_dir, executable, '--help')

    assert status.success?, "#{executable} --help failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, usage
    assert_empty stderr
  end

  def assert_installed_hook_errors(gem_home, dir, run_dir)
    state_file = dir.join('state', 'hook.json')
    outbox_dir = dir.join('outbox')
    arguments = [
      '--state-file', state_file.to_s,
      '--outbox-dir', outbox_dir.to_s,
      '--event', 'UserPromptSubmit'
    ]

    stdout, stderr, status = run_installed_executable(
      gem_home, dir, run_dir, 'codex-notify-hook', *arguments, stdin_data: '{}'
    )
    assert_equal 2, status.exitstatus
    assert_empty stdout
    assert_includes stderr, 'need --token/--channel'

    stdout, stderr, status = run_installed_executable(
      gem_home,
      dir,
      run_dir,
      'codex-notify-hook',
      *arguments,
      env: { 'SLACK_BOT_TOKEN' => 'xoxb-package-test', 'SLACK_CHANNEL' => 'CPACKAGETEST' }
    )
    assert_equal 2, status.exitstatus
    assert_empty stdout
    assert_includes stderr, 'hook stdin is empty'
    refute state_file.exist?
    refute outbox_dir.exist?
  end

  def run_installed_executable(gem_home, dir, run_dir, executable, *arguments, env: {}, stdin_data: '')
    Open3.capture3(
      isolated_environment(gem_home, dir).merge(env),
      gem_home.join('bin', executable).to_s,
      *arguments,
      stdin_data:,
      chdir: run_dir.to_s,
      unsetenv_others: true
    )
  end

  def isolated_environment(gem_home, dir)
    {
      'GEM_HOME' => gem_home.to_s,
      'GEM_PATH' => gem_home.to_s,
      'GEM_SPEC_CACHE' => dir.join('gem-spec-cache').to_s,
      'HOME' => dir.join('home').to_s,
      'LANG' => ENV.fetch('LANG', 'C.UTF-8'),
      'PATH' => ENV.fetch('PATH'),
      'USER' => 'package-test',
      'XDG_CONFIG_HOME' => dir.join('xdg-config').to_s
    }
  end
end
