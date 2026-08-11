# frozen_string_literal: true

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
      source_root = dir.join('source')
      source_root.mkpath
      copy_package_sources(source_root)
      refute source_root.join('.git').exist?

      package_path = dir.join("codex-notify-#{CodexNotify::VERSION}.gem")
      env = { 'BUNDLE_GEMFILE' => nil, 'RUBYLIB' => nil, 'RUBYOPT' => nil }
      stdout, stderr, status = Open3.capture3(
        env,
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

  def copy_package_sources(destination)
    (expected_package_files + ['codex-notify.gemspec']).each do |relative_path|
      target = destination.join(relative_path)
      target.dirname.mkpath
      FileUtils.cp(ROOT.join(relative_path), target, preserve: true)
    end
  end
end
