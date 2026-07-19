# frozen_string_literal: true

require 'json'
require 'pathname'
require 'securerandom'
require 'time'
require_relative 'secret_protection'

module CodexNotify
  class SlackOutbox
    VERSION = 1
    MAX_JOBS = 10_000
    MAX_BYTES = 64 * 1024 * 1024

    class Error < StandardError; end
    class CapacityError < Error; end

    def initialize(path, clock: -> { Time.now.utc })
      @path = Pathname(path)
      @clock = clock
    end

    attr_reader :path

    def enqueue(channel:, ordering_key:, generation:, action:, chunks:, recovery_chunks: [])
      with_state_lock do
        enforce_capacity!
        sequence = allocate_sequence
        job = {
          'version' => VERSION,
          'id' => SecureRandom.uuid,
          'sequence' => sequence,
          'channel' => channel.to_s,
          'ordering_key' => ordering_key.to_s,
          'generation' => generation.to_i,
          'action' => action.to_s,
          'message_chunks' => redact_chunks(chunks),
          'recovery_root_chunks' => redact_chunks(recovery_chunks),
          'phase' => 'pending',
          'next_chunk' => 0,
          'resolved_thread_ts' => nil,
          'attempt_count' => 0,
          'ambiguous_attempt_count' => 0,
          'next_attempt_at' => nil,
          'last_error' => nil,
          'created_at' => now.iso8601,
          'updated_at' => now.iso8601
        }
        write_job(job)
        job['id']
      end
    end

    def pending_root?(ordering_key, generation:)
      jobs(:pending).any? do |job|
        job['ordering_key'] == ordering_key.to_s && job['generation'] == generation.to_i &&
          %w[ensure_thread root_or_reply].include?(job['action'])
      end
    end

    def jobs(status = :pending)
      directory(status).glob('*.json').map { |file| read_job(file) }.sort_by { |job| job['sequence'] }
    end

    def update(job)
      job['updated_at'] = now.iso8601
      with_state_lock { write_job(job) }
    end

    def complete(job)
      with_state_lock { job_path(job, :pending).delete if job_path(job, :pending).exist? }
    end

    def move(job, status)
      with_state_lock do
        source = job_path(job, :pending)
        target = job_path(job, status)
        target.dirname.mkpath
        File.chmod(0o700, target.dirname)
        File.rename(source, target) if source.exist?
      end
    end

    def try_drain_lock
      prepare_directories
      File.open(@path.join('locks/drain.lock'), File::RDWR | File::CREAT, 0o600) do |file|
        return false unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
        true
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    end

    def status_rows
      %i[pending needs_review failed].flat_map do |status|
        jobs(status).map do |job|
          {
            status: status.to_s.tr('_', '-'), id: job['id'], sequence: job['sequence'],
            created_at: job['created_at'], error: job.dig('last_error', 'code')
          }
        end
      end
    end

    def retry(id)
      with_state_lock do
        source = %i[needs_review failed].map { |status| directory(status).join("#{id}.json") }.find(&:exist?)
        raise Error, "outbox job not found: #{id}" unless source

        job = read_job(source)
        job['next_attempt_at'] = nil
        job['last_error'] = nil
        job['ambiguous_attempt_count'] = 0
        source.delete
        write_job(job)
      end
    end

    private

    def now = @clock.call.utc

    def prepare_directories
      @path.mkpath
      File.chmod(0o700, @path)
      %i[pending needs_review failed].each do |status|
        directory(status).mkpath
        File.chmod(0o700, directory(status))
      end
      @path.join('locks').mkpath
      File.chmod(0o700, @path.join('locks'))
    end

    def directory(status)
      @path.join(status.to_s.tr('_', '-'))
    end

    def with_state_lock
      prepare_directories
      File.open(@path.join('locks/state.lock'), File::RDWR | File::CREAT, 0o600) do |file|
        raise Error, 'could not lock outbox state' unless file.flock(File::LOCK_EX)

        cleanup_temp_files
        yield
      end
    end

    def cleanup_temp_files
      [@path, *%i[pending needs_review failed].map { |status| directory(status) }].each do |dir|
        dir.glob('.*.tmp-*').each { |file| file.delete if file.file? }
      end
    end

    def allocate_sequence
      index = @path.join('index.json')
      value = index.exist? ? JSON.parse(index.read).fetch('next_sequence', 1).to_i : 1
      atomic_write(index, JSON.generate('next_sequence' => value + 1))
      value
    rescue JSON::ParserError
      raise Error, 'outbox index is invalid'
    end

    def enforce_capacity!
      files = %i[pending needs_review failed].flat_map { |status| directory(status).glob('*.json') }
      bytes = files.sum { |file| file.size }
      raise CapacityError, "outbox capacity reached (#{files.size} jobs, #{bytes} bytes)" if files.size >= MAX_JOBS || bytes >= MAX_BYTES
    end

    def redact_chunks(chunks)
      Array(chunks).map { |chunk| SecretProtection.redact(chunk.to_s) }
    end

    def write_job(job)
      validate_job!(job)
      atomic_write(job_path(job, :pending), JSON.generate(job))
    end

    def read_job(file)
      job = JSON.parse(file.read)
      validate_job!(job)
      job
    rescue JSON::ParserError
      raise Error, "outbox job is invalid: #{file.basename}"
    end

    def validate_job!(job)
      required = %w[version id sequence channel ordering_key generation action message_chunks phase next_chunk]
      raise Error, 'outbox job is invalid' unless job.is_a?(Hash) && job['version'] == VERSION && required.all? { |key| job.key?(key) }
    end

    def job_path(job, status)
      directory(status).join("#{job.fetch('id')}.json")
    end

    def atomic_write(path, content)
      path.dirname.mkpath
      tmp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
      File.rename(tmp, path)
    ensure
      tmp.delete if defined?(tmp) && tmp.exist?
    end
  end
end
