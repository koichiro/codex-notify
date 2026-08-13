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
    CHANGELOG.md
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
    assert_equal '1.0.0', spec.version.to_s
    assert_equal CodexNotify::VERSION, spec.version.to_s
    assert_equal ['Koichiro Ohba'], spec.authors
    assert_equal ['MIT'], spec.licenses
    assert_equal 'https://github.com/koichiro/codex-notify', spec.homepage
    assert_equal "#{spec.homepage}/tree/v#{spec.version}", spec.metadata.fetch('source_code_uri')
    assert_equal "#{spec.homepage}/issues", spec.metadata.fetch('bug_tracker_uri')
    assert_equal "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md", spec.metadata.fetch('changelog_uri')
    assert_equal "#{spec.homepage}#readme", spec.metadata.fetch('documentation_uri')
    assert_equal 'true', spec.metadata.fetch('rubygems_mfa_required')
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

  def copy_package_sources(destination)
    (expected_package_files + ['codex-notify.gemspec']).each do |relative_path|
      target = destination.join(relative_path)
      target.dirname.mkpath
      FileUtils.cp(ROOT.join(relative_path), target, preserve: true)
    end
  end
end
