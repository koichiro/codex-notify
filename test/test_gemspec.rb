# frozen_string_literal: true

require 'bundler'
require 'open3'
require 'rbconfig'
require 'rubygems/package'
require_relative 'test_helper'

class CodexNotifyGemspecTest < Minitest::Test
  GEMSPEC_PATH = ROOT.join('codex-notify.gemspec')
  FIXED_PACKAGE_FILES = %w[
    bin/codex-notify
    bin/codex-notify-hook
    LICENSE
    README.md
  ].freeze
  FORBIDDEN_PACKAGE_ROOTS = %w[
    .bundle
    .codex
    .env
    .git
    .session
    pkg
    test
    vendor
  ].freeze

  def test_metadata_and_ruby_requirement
    spec = load_gemspec

    assert_equal 'codex-notify', spec.name
    assert_equal CodexNotify::VERSION, spec.version.to_s
    assert_equal ['Koichiro Ohba'], spec.authors
    assert_equal ['MIT'], spec.licenses
    assert_equal 'https://github.com/koichiro/codex-notify', spec.homepage
    assert_equal spec.homepage, spec.metadata.fetch('source_code_uri')
    assert_equal "#{spec.homepage}/issues", spec.metadata.fetch('bug_tracker_uri')
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.4.0'))
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.3.9'))
    assert_equal ['lib'], spec.require_paths
  end

  def test_registers_both_executable_files
    spec = load_gemspec

    assert_equal 'bin', spec.bindir
    assert_equal %w[codex-notify codex-notify-hook], spec.executables
    spec.executables.each do |executable|
      path = ROOT.join(spec.bindir, executable)
      assert path.file?, "expected #{path} to exist"
      assert path.executable?, "expected #{path} to be executable"
    end
  end

  def test_executable_bootstraps_use_only_normal_gem_requires
    requires = {
      'codex-notify' => "require 'codex_notify'",
      'codex-notify-hook' => "require 'codex_notify/hook_cli'"
    }

    requires.each do |executable, require_line|
      content = ROOT.join('bin', executable).read
      assert_includes content, require_line
      refute_includes content, 'BUNDLE_GEMFILE'
      refute_includes content, 'bundler/setup'
      refute_includes content, 'rbenv'
      refute_includes content, '.ruby-version'
      refute_includes content, '$LOAD_PATH'
      refute_includes content, 'legacy_checkout_root'
    end
  end

  def test_declares_only_dotenv_as_a_runtime_dependency
    spec = load_gemspec
    dependency = spec.runtime_dependencies.fetch(0)

    assert_equal ['dotenv'], spec.runtime_dependencies.map(&:name)
    assert_equal Gem::Requirement.new('~> 3.2'), dependency.requirement
    assert_empty spec.development_dependencies
  end

  def test_gemfile_uses_gemspec_and_keeps_development_tools_in_non_runtime_groups
    definition = Bundler::Definition.build(ROOT.join('Gemfile'), ROOT.join('Gemfile.lock'), nil)
    dependencies = definition.dependencies.to_h { |dependency| [dependency.name, dependency.groups] }

    assert_equal %w[codex-notify minitest rake], dependencies.keys.sort
    assert_equal [:default], dependencies.fetch('codex-notify')
    assert_equal %i[development test], dependencies.fetch('minitest')
    assert_equal %i[development test], dependencies.fetch('rake')
    refute dependencies.key?('dotenv')
  end

  def test_package_files_match_the_explicit_allowlist
    files = load_gemspec.files

    assert_equal expected_package_files, files
    files.each do |path|
      refute Pathname(path).absolute?, "package path must be relative: #{path}"
      refute_includes Pathname(path).each_filename.to_a, '..'
      refute_includes FORBIDDEN_PACKAGE_ROOTS, Pathname(path).each_filename.first
    end
  end

  def test_builds_strictly_without_git_or_development_files
    Dir.mktmpdir('codex-notify-gem-test') do |tmpdir|
      dir = Pathname(tmpdir)
      package_path = build_package(dir)
      package = Gem::Package.new(package_path.to_s)
      assert_equal expected_package_files, package.spec.files
      assert_equal expected_package_files, package.contents.sort
    end
  end

  def test_installed_gem_loads_and_runs_both_executables_outside_the_checkout
    Dir.mktmpdir('codex-notify-install-test') do |tmpdir|
      dir = Pathname(tmpdir)
      package_path = build_package(dir)
      gem_home = dir.join('gem-home')
      dotenv_spec = Gem::Specification.find_by_name('dotenv', '~> 3.2')
      dotenv_package = Pathname(dotenv_spec.cache_file)
      assert dotenv_package.file?, "expected cached gem at #{dotenv_package}"

      install_local_gem(dotenv_package, gem_home, dir)
      install_local_gem(package_path, gem_home, dir)

      installed_specs = gem_home.join('specifications').glob('*.gemspec').map { |path| path.basename.to_s }.sort
      assert_equal [
        "codex-notify-#{CodexNotify::VERSION}.gemspec",
        "dotenv-#{dotenv_spec.version}.gemspec"
      ], installed_specs

      run_dir = dir.join('run')
      run_dir.mkpath
      script = <<~'RUBY'
        require 'codex_notify'

        feature = $LOADED_FEATURES.find { |path| path.end_with?('/codex_notify.rb') }
        spec = Gem.loaded_specs.fetch('codex-notify')
        gem_home = File.realpath(ENV.fetch('GEM_HOME'))
        installed_root = File.realpath(spec.full_gem_path)
        abort 'codex_notify was not loaded from its installed gem' unless feature&.start_with?(spec.full_gem_path)
        abort 'codex_notify was not loaded from GEM_HOME' unless installed_root.start_with?("#{gem_home}/")
        abort 'source checkout is present on the load path' if $LOAD_PATH.any? do |path|
          File.expand_path(path).start_with?(ENV.fetch('SOURCE_ROOT'))
        end

        puts "#{CodexNotify::VERSION} #{Gem.loaded_specs.fetch('dotenv').version}"
      RUBY
      stdout, stderr, status = Open3.capture3(
        isolated_gem_environment(gem_home, dir).merge('SOURCE_ROOT' => ROOT.to_s),
        RbConfig.ruby,
        '-e',
        script,
        chdir: run_dir.to_s
      )

      assert status.success?, "installed gem load failed:\n#{stdout}\n#{stderr}"
      assert_equal "#{CodexNotify::VERSION} #{dotenv_spec.version}\n", stdout
      assert_empty stderr

      assert_installed_help(gem_home, dir, run_dir, 'codex-notify', 'Usage: codex-notify [options]')
      assert_installed_help(gem_home, dir, run_dir, 'codex-notify-hook', 'Usage: codex-notify-hook [options]')
      assert_installed_hook_errors(gem_home, dir, run_dir)
    end
  end

  private

  def load_gemspec
    Gem::Specification.load(GEMSPEC_PATH.to_s) || raise('failed to load gemspec')
  end

  def expected_package_files
    (Dir.chdir(ROOT) { Dir['lib/**/*.rb'] } + FIXED_PACKAGE_FILES).sort
  end

  def build_package(dir)
    source_root = dir.join('source')
    source_root.mkpath
    copy_package_sources(source_root)
    refute source_root.join('.git').exist?

    package_path = dir.join("codex-notify-#{CodexNotify::VERSION}.gem")
    stdout, stderr, status = Open3.capture3(
      { 'BUNDLE_GEMFILE' => nil, 'RUBYLIB' => nil, 'RUBYOPT' => nil },
      RbConfig.ruby,
      '-S',
      'gem',
      'build',
      'codex-notify.gemspec',
      '--strict',
      '--output',
      package_path.to_s,
      chdir: source_root.to_s
    )

    assert status.success?, "gem build failed:\n#{stdout}\n#{stderr}"
    assert package_path.file?
    package_path
  end

  def install_local_gem(package_path, gem_home, dir)
    stdout, stderr, status = Open3.capture3(
      isolated_gem_environment(gem_home, dir),
      RbConfig.ruby,
      '-S',
      'gem',
      'install',
      package_path.to_s,
      '--local',
      '--ignore-dependencies',
      '--no-document',
      '--install-dir',
      gem_home.to_s
    )

    assert status.success?, "local gem install failed:\n#{stdout}\n#{stderr}"
  end

  def isolated_gem_environment(gem_home, dir)
    {
      'BUNDLE_GEMFILE' => nil,
      'GEM_HOME' => gem_home.to_s,
      'GEM_PATH' => gem_home.to_s,
      'GEM_SPEC_CACHE' => dir.join('gem-spec-cache').to_s,
      'HOME' => dir.join('home').to_s,
      'RUBYLIB' => nil,
      'RUBYOPT' => nil,
      'SLACK_BOT_TOKEN' => nil,
      'SLACK_CHANNEL' => nil,
      'XDG_CONFIG_HOME' => dir.join('xdg-config').to_s
    }
  end

  def assert_installed_help(gem_home, dir, run_dir, executable, usage)
    stdout, stderr, status = run_installed_executable(gem_home, dir, run_dir, executable, '--help')

    assert status.success?, "#{executable} --help failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, usage
    assert_empty stderr
  end

  def assert_installed_hook_errors(gem_home, dir, run_dir)
    stdout, stderr, status = run_installed_executable(
      gem_home,
      dir,
      run_dir,
      'codex-notify-hook',
      '--event',
      'UserPromptSubmit',
      stdin_data: '{}'
    )
    assert_equal 2, status.exitstatus
    assert_empty stdout
    assert_includes stderr, 'need --token/--channel'

    stdout, stderr, status = run_installed_executable(
      gem_home,
      dir,
      run_dir,
      'codex-notify-hook',
      '--event',
      'UserPromptSubmit',
      env: { 'SLACK_BOT_TOKEN' => 'xoxb-test', 'SLACK_CHANNEL' => 'CTEST' }
    )
    assert_equal 2, status.exitstatus
    assert_empty stdout
    assert_includes stderr, 'hook stdin is empty'
    refute dir.join('home', '.codex-notify-hook').exist?
  end

  def run_installed_executable(gem_home, dir, run_dir, executable, *arguments, env: {}, stdin_data: '')
    Open3.capture3(
      isolated_gem_environment(gem_home, dir).merge(env),
      gem_home.join('bin', executable).to_s,
      *arguments,
      stdin_data:,
      chdir: run_dir.to_s
    )
  end

  def copy_package_sources(destination)
    (expected_package_files + ['codex-notify.gemspec']).each do |relative_path|
      target = destination.join(relative_path)
      target.dirname.mkpath
      FileUtils.cp(ROOT.join(relative_path), target, preserve: true)
    end
  end
end
