# frozen_string_literal: true

require 'stringio'
require 'yaml'
require_relative 'test_helper'
require_relative '../script/dependency_audit'

class DependencyAuditTest < Minitest::Test
  class OfflineDatabase < Bundler::Audit::Database
    attr_accessor :git_repository, :update_result, :update_error
    attr_reader :update_calls

    def initialize(path)
      super
      @git_repository = true
      @update_result = true
      @update_calls = 0
    end

    def git? = @git_repository

    def update!(quiet:)
      @update_calls += 1
      raise @update_error if @update_error

      @update_result
    end
  end

  class DatabaseSource
    attr_accessor :existing, :download_error
    attr_reader :download_calls

    def initialize(database)
      @database = database
      @existing = true
      @download_calls = 0
    end

    def exists?(_path) = @existing
    def new(_path) = @database

    def download(path:, quiet:)
      @download_calls += 1
      raise @download_error if @download_error

      @database
    end
  end

  def setup
    super
    @project = @test_working_directory.join('project').tap(&:mkpath)
    @database_path = @test_working_directory.join('database').tap(&:mkpath)
    write_advisory('bundler', 'CVE-2099-0001')
    write_advisory('synthetic-gem', 'CVE-2099-0002')
    @database = OfflineDatabase.new(@database_path.to_s)
    @source = DatabaseSource.new(@database)
    @stdout = StringIO.new
    @stderr = StringIO.new
    write_lockfile
  end

  def test_safe_gems_and_bundler_pass_after_refresh
    assert_equal 0, audit
    assert_equal 1, @database.update_calls
    assert_includes @stdout.string, 'No vulnerabilities found'
    assert_empty @stderr.string
  end

  def test_vulnerable_bundled_with_fails_even_when_bundler_is_not_a_spec
    write_lockfile(bundler: '1.0.0')
    scanner = Bundler::Audit::Scanner.new(@project.to_s, 'Gemfile.lock', @database)
    refute scanner.report.vulnerable? # Stock scanner misses BUNDLED WITH.
    assert_equal 1, audit
    assert_includes @stdout.string, 'bundler 1.0.0 (CVE-2099-0001)'
    refute_includes @stdout.string, 'No vulnerabilities found'
  end

  def test_vulnerable_regular_gem_still_fails
    write_lockfile(gem_version: '1.0.0')
    assert_equal 1, audit
    assert_includes @stdout.string, 'synthetic-gem 1.0.0 (CVE-2099-0002)'
  end

  def test_project_advisory_ignores_cannot_hide_locked_gem_or_bundler_vulnerabilities
    @project.join('.bundler-audit.yml').write(YAML.dump('ignore' => %w[CVE-2099-0001 CVE-2099-0002]))
    %w[2.0.0 1.0.0].each do |bundler_version|
      write_lockfile(bundler: bundler_version, gem_version: '1.0.0')
      @stdout.truncate(0)
      @stdout.rewind
      scanner = Bundler::Audit::Scanner.new(@project.to_s, 'Gemfile.lock', @database)
      refute scanner.report.vulnerable? # Stock scanner honors the project's ignores.

      assert_equal 1, audit
      assert_includes @stdout.string, 'synthetic-gem 1.0.0 (CVE-2099-0002)'
      assert_includes @stdout.string, 'bundler 1.0.0 (CVE-2099-0001)' if bundler_version == '1.0.0'
      refute_includes @stdout.string, 'No vulnerabilities found'
    end
  end

  def test_insecure_sources_still_fail_without_printing_source_credentials
    # A numeric documentation address avoids DNS lookup in bundler-audit.
    write_lockfile(source: 'http://synthetic-user:synthetic-password@203.0.113.1/')
    assert_equal 1, audit
    assert_includes @stdout.string, 'Insecure gem source detected'
    refute_includes @stdout.string + @stderr.string, 'synthetic-password'
  end

  def test_missing_bundled_with_fails
    write_lockfile(bundler: nil)
    assert_equal 1, audit
    assert_includes @stderr.string, 'must record a BUNDLED WITH version'
    assert_empty @stdout.string
  end

  def test_missing_or_invalid_lockfile_fails
    @project.join('Gemfile.lock').unlink
    assert_equal 1, audit
    write_lockfile(bundler: 'invalid-version')
    assert_equal 1, audit
    refute_includes @stdout.string, 'No vulnerabilities found'
  end

  def test_non_git_database_fails_without_scanning_or_attempting_update
    @database.git_repository = false
    assert_equal 1, audit
    assert_equal 0, @database.update_calls
    assert_includes @stderr.string, 'must be a Git repository'
    assert_empty @stdout.string
  end

  def test_skipped_or_failed_update_fails_without_scanning
    [nil, false].each do |result|
      @database.update_result = result
      assert_equal 1, audit
    end
    @database.update_error = Bundler::Audit::Database::UpdateFailed.new('synthetic-sensitive-detail')
    assert_equal 1, audit
    assert_empty @stdout.string
    refute_includes @stderr.string, 'synthetic-sensitive-detail'
  end

  def test_missing_database_is_downloaded_before_scanning
    @source.existing = false
    assert_equal 0, audit
    assert_equal 1, @source.download_calls
    assert_equal 0, @database.update_calls
  end

  def test_download_failure_fails_without_scanning
    @source.existing = false
    @source.download_error = Bundler::Audit::Database::DownloadFailed.new('synthetic-sensitive-detail')
    assert_equal 1, audit
    assert_empty @stdout.string
    refute_includes @stderr.string, 'synthetic-sensitive-detail'
  end

  private

  def audit
    CodexNotify::DependencyAudit.new(root: @project.to_s, database_path: @database_path.to_s,
                                    database_class: @source, stdout: @stdout, stderr: @stderr).run
  end

  def write_advisory(gem_name, id)
    directory = @database_path.join('gems', gem_name).tap(&:mkpath)
    directory.join("#{id}.yml").write(YAML.dump(
      'gem' => gem_name, 'cve' => id.delete_prefix('CVE-'), 'date' => '2099-01-01',
      'url' => 'https://example.invalid/synthetic-advisory', 'title' => 'Synthetic test advisory',
      'description' => 'Synthetic advisory for offline tests only.', 'patched_versions' => ['>= 2.0.0']
    ))
  end

  def write_lockfile(bundler: '2.0.0', gem_version: '2.0.0', source: 'https://rubygems.org/')
    content = <<~LOCK
      GEM
        remote: #{source}
        specs:
          synthetic-gem (#{gem_version})

      PLATFORMS
        ruby

      DEPENDENCIES
        synthetic-gem
    LOCK
    content += "\nBUNDLED WITH\n  #{bundler}\n" if bundler
    @project.join('Gemfile.lock').write(content)
  end
end
