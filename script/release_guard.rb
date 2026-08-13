# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'uri'
require 'rubygems'
require_relative '../lib/codex_notify/version'

module ReleaseGuard
  class Error < StandardError; end

  class CommandRunner
    def capture(*command)
      stdout, _stderr, status = Open3.capture3(*command)
      raise Error, "release validation command failed: #{command.first}" unless status.success?

      stdout
    end
  end

  class Registry
    RUBYGEMS_URI = URI('https://rubygems.org/api/v1/versions/codex-notify.json')
    GITHUB_API = 'https://api.github.com'

    def version_published?(version)
      response = get(RUBYGEMS_URI)
      return false if response.is_a?(Net::HTTPNotFound)
      raise Error, 'RubyGems version state could not be verified' unless response.is_a?(Net::HTTPSuccess)

      versions = JSON.parse(response.body)
      raise Error, 'RubyGems returned an invalid version list' unless versions.is_a?(Array)

      versions.any? { |entry| entry.is_a?(Hash) && entry['number'] == version }
    rescue JSON::ParserError
      raise Error, 'RubyGems returned an invalid version list'
    end

    def github_release_exists?(repository, tag)
      escaped_tag = URI.encode_www_form_component(tag)
      response = get(URI("#{GITHUB_API}/repos/#{repository}/releases/tags/#{escaped_tag}"))
      return false if response.is_a?(Net::HTTPNotFound)
      return true if response.is_a?(Net::HTTPSuccess)

      raise Error, 'GitHub Release state could not be verified'
    end

    private

    def get(uri)
      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/vnd.github+json' if uri.host == 'api.github.com'
      request['User-Agent'] = 'codex-notify-release-guard'
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end
    rescue IOError, SystemCallError, Timeout::Error, SocketError
      raise Error, "#{uri.host} state could not be verified"
    end
  end

  class Validator
    STABLE_SEMVER = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/
    COMMIT_SHA = /\A[0-9a-f]{40}\z/
    REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

    def initialize(version:, expected_sha:, repository:, root:, runner: CommandRunner.new, registry: Registry.new)
      @version = version
      @expected_sha = expected_sha
      @repository = repository
      @root = File.expand_path(root)
      @runner = runner
      @registry = registry
    end

    def validate!
      validate_inputs!
      validate_workflow_context!
      validate_versions!
      validate_main!
      validate_tag!
      validate_remote_state!
      true
    end

    private

    def validate_inputs!
      raise Error, 'version must be a stable Semantic Version' unless @version.match?(STABLE_SEMVER)
      raise Error, 'release commit must be a full commit SHA' unless @expected_sha.match?(COMMIT_SHA)
      raise Error, 'repository identifier is invalid' unless @repository.match?(REPOSITORY)
    end

    def validate_workflow_context!
      expected_workflow = "#{@repository}/.github/workflows/release.yml@refs/heads/main"
      valid = ENV['GITHUB_ACTIONS'] == 'true' &&
              ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' &&
              ENV['GITHUB_REF'] == 'refs/heads/main' &&
              ENV['GITHUB_WORKFLOW_REF'] == expected_workflow
      raise Error, 'release must run from release.yml selected from main' unless valid
    end

    def validate_versions!
      gemspec = Gem::Specification.load(File.join(@root, 'codex-notify.gemspec'))
      raise Error, 'gemspec could not be loaded' unless gemspec
      raise Error, 'release version does not match CodexNotify::VERSION' unless CodexNotify::VERSION == @version
      raise Error, 'release version does not match the gemspec' unless gemspec.version.to_s == @version
    end

    def validate_main!
      git('fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main')
      head = git('rev-parse', 'HEAD').strip
      remote_main = git('rev-parse', 'refs/remotes/origin/main').strip
      raise Error, 'checked-out commit is not the requested release commit' unless head == @expected_sha
      raise Error, 'release commit is not the current origin/main' unless remote_main == @expected_sha
    end

    def validate_tag!
      tag = "v#{@version}"
      remote_refs = git('ls-remote', '--tags', 'origin', "refs/tags/#{tag}", "refs/tags/#{tag}^{}")
      return if remote_refs.strip.empty?

      git('fetch', '--no-tags', 'origin', "+refs/tags/#{tag}:refs/tags/#{tag}")
      raise Error, 'existing release tag is not annotated' unless git('cat-file', '-t', tag).strip == 'tag'

      target = git('rev-list', '-n', '1', tag).strip
      raise Error, 'existing release tag points to a different commit' unless target == @expected_sha
    end

    def validate_remote_state!
      raise Error, 'release version is already published to RubyGems.org' if @registry.version_published?(@version)
      if @registry.github_release_exists?(@repository, "v#{@version}")
        raise Error, 'matching GitHub Release already exists before publication'
      end
    end

    def git(*arguments)
      @runner.capture('git', '-C', @root, *arguments)
    end
  end

  module CLI
    module_function

    def run(arguments)
      options = { root: File.expand_path('..', __dir__) }
      OptionParser.new do |parser|
        parser.on('--version VERSION') { |value| options[:version] = value }
        parser.on('--expected-sha SHA') { |value| options[:expected_sha] = value }
        parser.on('--repository OWNER/NAME') { |value| options[:repository] = value }
      end.parse!(arguments)

      required = %i[version expected_sha repository]
      raise Error, "missing required option: #{required.find { |key| options[key].nil? }}" if required.any? { |key| options[key].nil? }

      Validator.new(**options).validate!
      puts "Release #{options.fetch(:version)} validation passed" if ENV['CODEX_NOTIFY_RELEASE_DEBUG'] == '1'
      0
    rescue Error, OptionParser::ParseError => e
      warn "release validation failed: #{e.message}"
      1
    end
  end
end

exit ReleaseGuard::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
