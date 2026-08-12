# frozen_string_literal: true

require 'coverage'

Coverage.start(lines: true)

require 'minitest/autorun'
require 'pathname'
require 'tmpdir'
require 'fileutils'

ROOT = Pathname(__dir__).join('..').expand_path
ORIGINAL_TEST_CWD = Pathname(Dir.pwd).expand_path
TEST_SANDBOX_ROOT = Pathname(Dir.mktmpdir('codex-notify-test')).realpath
TEST_HOME = TEST_SANDBOX_ROOT.join('home')
TEST_XDG_CONFIG_HOME = TEST_SANDBOX_ROOT.join('xdg-config')
TEST_WORKING_DIRECTORIES = TEST_SANDBOX_ROOT.join('working-directories')
[TEST_HOME, TEST_XDG_CONFIG_HOME, TEST_WORKING_DIRECTORIES].each(&:mkpath)

module TestEnvironment
  module_function

  def configuration_key?(key)
    key.start_with?('SLACK_', 'CODEX_NOTIFY_') || %w[CODEX_HOOK_EVENT CODEX_PROMPT].include?(key)
  end

  def isolated_environment
    ENV.to_h.reject { |key, _value| configuration_key?(key) }.merge(
      'HOME' => TEST_HOME.to_s,
      'XDG_CONFIG_HOME' => TEST_XDG_CONFIG_HOME.to_s
    )
  end

  def restore!
    Dir.chdir(ORIGINAL_TEST_CWD)
    FileUtils.remove_entry(TEST_SANDBOX_ROOT) if TEST_SANDBOX_ROOT.exist?
  end
end

ISOLATED_TEST_ENV = TestEnvironment.isolated_environment.freeze
ENV.replace(ISOLATED_TEST_ENV)

$LOAD_PATH.unshift(ROOT.join('lib').to_s)

require 'codex_notify'
require 'codex_notify/cli'

module HermeticTestCase
  def before_setup
    ENV.replace(ISOLATED_TEST_ENV)
    @test_working_directory = Pathname(Dir.mktmpdir('case-', TEST_WORKING_DIRECTORIES.to_s))
    Dir.chdir(@test_working_directory)
    super
  end

  def after_teardown
    super
  ensure
    Dir.chdir(ORIGINAL_TEST_CWD)
    ENV.replace(ISOLATED_TEST_ENV)
    if @test_working_directory&.exist?
      FileUtils.remove_entry(@test_working_directory)
    end
  end
end

Minitest::Test.prepend(HermeticTestCase)

module CoverageReport
  THRESHOLD = 90.0

  module_function

  def report!
    result = Coverage.result
    root_lib = ROOT.join('lib').to_s
    tracked = result.select { |path, _| path.start_with?(root_lib) }
    lines = tracked.values.flat_map { |entry| entry.fetch(:lines, []) }.compact
    covered = lines.count { |count| count.positive? }
    total = lines.size
    percent = total.zero? ? 100.0 : (covered * 100.0 / total)
    warn format('Coverage: %.2f%% (%d/%d)', percent, covered, total)
    raise "Coverage below #{THRESHOLD}% (actual #{format('%.2f', percent)}%)" if percent < THRESHOLD
  end
end

Minitest.after_run do
  CoverageReport.report!
ensure
  TestEnvironment.restore!
end
