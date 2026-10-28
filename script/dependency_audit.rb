# frozen_string_literal: true

require 'bundler/audit/scanner'

module CodexNotify
  class DependencyAudit
    class Error < StandardError; end

    def initialize(root:, database_path: Bundler::Audit::Database::DEFAULT_PATH,
                   database_class: Bundler::Audit::Database, stdout: $stdout, stderr: $stderr)
      @root = root
      @database_path = database_path
      @database_class = database_class
      @stdout = stdout
      @stderr = stderr
    end

    def run
      database = refresh_database
      scanner = Bundler::Audit::Scanner.new(@root, 'Gemfile.lock', database)
      version = scanner.lockfile.bundler_version
      raise Error, 'Gemfile.lock must record a BUNDLED WITH version' unless version

      report = scanner.report
      bundler = Gem::Specification.new do |spec|
        spec.name = 'bundler'
        spec.version = version
      end
      database.check_gem(bundler) do |advisory|
        report << Bundler::Audit::Results::UnpatchedGem.new(bundler, advisory)
      end

      report.each do |result|
        if result.is_a?(Bundler::Audit::Results::UnpatchedGem)
          @stdout.puts "Vulnerable gem: #{result.gem.name} #{result.gem.version} (#{result.advisory.id})"
        else
          @stdout.puts 'Insecure gem source detected'
        end
      end
      @stdout.puts 'No vulnerabilities found in locked gems or Bundler' unless report.vulnerable?
      report.vulnerable? ? 1 : 0
    rescue Error => e
      @stderr.puts "Dependency audit failed: #{e.message}"
      1
    rescue Bundler::Audit::Database::DownloadFailed, Bundler::Audit::Database::UpdateFailed,
           Bundler::GemfileLockNotFound, Bundler::LockfileError, ArgumentError, SystemCallError
      @stderr.puts 'Dependency audit failed: unable to refresh the advisory database or read the lockfile'
      1
    end

    private

    def refresh_database
      unless @database_class.exists?(@database_path)
        return @database_class.download(path: @database_path, quiet: true)
      end

      database = @database_class.new(@database_path)
      unless database.git? && database.update!(quiet: true) == true
        raise Error, 'advisory database must be a Git repository and refresh successfully'
      end

      database
    end
  end
end

exit CodexNotify::DependencyAudit.new(root: File.expand_path('..', __dir__)).run if $PROGRAM_NAME == __FILE__
