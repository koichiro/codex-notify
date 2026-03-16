# frozen_string_literal: true

require 'coverage'

Coverage.start(lines: true)

require 'minitest/autorun'
require 'pathname'

ROOT = Pathname(__dir__).join('..').expand_path
$LOAD_PATH.unshift(ROOT.join('lib').to_s)

require 'codex_notify/cli'

module CoverageReport
  THRESHOLD = 80.0

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
end
