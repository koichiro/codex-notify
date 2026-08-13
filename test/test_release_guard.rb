# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../script/release_guard'

class ReleaseGuardTest < Minitest::Test
  SHA = 'a' * 40

  class FakeRunner
    attr_reader :commands

    def initialize(tag_refs: '', tag_type: 'tag', tag_target: SHA, head: SHA, main: SHA)
      @tag_refs = tag_refs
      @tag_type = tag_type
      @tag_target = tag_target
      @head = head
      @main = main
      @commands = []
    end

    def capture(*command)
      @commands << command
      case command
      in ['git', '-C', _, 'fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main'] then ''
      in ['git', '-C', _, 'rev-parse', 'HEAD'] then "#{@head}\n"
      in ['git', '-C', _, 'rev-parse', 'refs/remotes/origin/main'] then "#{@main}\n"
      in ['git', '-C', _, 'ls-remote', '--tags', 'origin', *] then @tag_refs
      in ['git', '-C', _, 'fetch', '--no-tags', 'origin', ref] if ref.start_with?('+refs/tags/') then ''
      in ['git', '-C', _, 'cat-file', '-t', _] then "#{@tag_type}\n"
      in ['git', '-C', _, 'rev-list', '-n', '1', _] then "#{@tag_target}\n"
      else raise "unexpected command: #{command.inspect}"
      end
    end
  end

  class FakeRegistry
    def initialize(published: false, release: false)
      @published = published
      @release = release
    end

    def version_published?(_version) = @published
    def github_release_exists?(_repository, _tag) = @release
  end

  def setup
    super
    ENV.update(
      'GITHUB_ACTIONS' => 'true',
      'GITHUB_EVENT_NAME' => 'workflow_dispatch',
      'GITHUB_REF' => 'refs/heads/main',
      'GITHUB_WORKFLOW_REF' => 'koichiro/codex-notify/.github/workflows/release.yml@refs/heads/main'
    )
  end

  def test_accepts_an_unpublished_release_without_a_tag
    assert validator.validate!
  end

  def test_accepts_retry_for_annotated_tag_on_same_commit
    runner = FakeRunner.new(tag_refs: "tag-object\trefs/tags/v#{CodexNotify::VERSION}\n")

    assert validator(runner:).validate!
  end

  def test_rejects_non_stable_or_non_canonical_versions
    %w[v1.0.0 01.0.0 1.0.0-rc1 1.0.0+build].each do |version|
      error = assert_raises(ReleaseGuard::Error) { validator(version:).validate! }
      assert_includes error.message, 'stable Semantic Version'
    end
  end

  def test_rejects_a_non_main_workflow
    ENV['GITHUB_REF'] = 'refs/heads/topic'

    error = assert_raises(ReleaseGuard::Error) { validator.validate! }
    assert_includes error.message, 'selected from main'
  end

  def test_rejects_when_main_has_moved
    runner = FakeRunner.new(main: 'b' * 40)

    error = assert_raises(ReleaseGuard::Error) { validator(runner:).validate! }
    assert_includes error.message, 'current origin/main'
  end

  def test_rejects_lightweight_or_conflicting_tags
    tag_refs = "object\trefs/tags/v#{CodexNotify::VERSION}\n"
    error = assert_raises(ReleaseGuard::Error) do
      validator(runner: FakeRunner.new(tag_refs:, tag_type: 'commit')).validate!
    end
    assert_includes error.message, 'not annotated'

    error = assert_raises(ReleaseGuard::Error) do
      validator(runner: FakeRunner.new(tag_refs:, tag_target: 'b' * 40)).validate!
    end
    assert_includes error.message, 'different commit'
  end

  def test_rejects_published_version_or_existing_release
    error = assert_raises(ReleaseGuard::Error) do
      validator(registry: FakeRegistry.new(published: true)).validate!
    end
    assert_includes error.message, 'already published'

    error = assert_raises(ReleaseGuard::Error) do
      validator(registry: FakeRegistry.new(release: true)).validate!
    end
    assert_includes error.message, 'already exists'
  end

  private

  def validator(version: CodexNotify::VERSION, runner: FakeRunner.new, registry: FakeRegistry.new)
    ReleaseGuard::Validator.new(
      version:,
      expected_sha: SHA,
      repository: 'koichiro/codex-notify',
      root: ROOT,
      runner:,
      registry:
    )
  end
end

class ReleaseRegistryTest < Minitest::Test
  class StubRegistry < ReleaseGuard::Registry
    def initialize(response)
      @response = response
    end

    private

    def get(_uri) = @response
  end

  def test_treats_missing_gem_and_release_as_absent
    registry = StubRegistry.new(response(Net::HTTPNotFound, ''))

    refute registry.version_published?('1.0.0')
    refute registry.github_release_exists?('koichiro/codex-notify', 'v1.0.0')
  end

  def test_detects_an_exact_published_version_and_existing_release
    registry = StubRegistry.new(response(Net::HTTPOK, '[{"number":"1.0.0"}]'))

    assert registry.version_published?('1.0.0')
    assert registry.github_release_exists?('koichiro/codex-notify', 'v1.0.0')
  end

  def test_fails_closed_on_invalid_registry_responses
    registry = StubRegistry.new(response(Net::HTTPOK, 'not-json'))
    assert_raises(ReleaseGuard::Error) { registry.version_published?('1.0.0') }

    registry = StubRegistry.new(response(Net::HTTPServiceUnavailable, ''))
    assert_raises(ReleaseGuard::Error) { registry.version_published?('1.0.0') }
    assert_raises(ReleaseGuard::Error) do
      registry.github_release_exists?('koichiro/codex-notify', 'v1.0.0')
    end
  end

  private

  def response(response_class, body)
    code = {
      Net::HTTPOK => '200',
      Net::HTTPNotFound => '404',
      Net::HTTPServiceUnavailable => '503'
    }.fetch(response_class)
    response_class.new('1.1', code, '').tap do |response|
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
    end
  end
end
