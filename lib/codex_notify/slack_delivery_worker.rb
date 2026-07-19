# frozen_string_literal: true

require 'time'
require_relative 'slack_client'

module CodexNotify
  class SlackDeliveryWorker
    STALE_THREAD_CODES = %w[thread_not_found message_not_found invalid_ts].freeze
    DRAIN_BUDGET = 10.0
    MAX_IMMEDIATE_ATTEMPTS = 3
    MAX_AMBIGUOUS_ATTEMPTS = 3
    BACKOFF_CAP = 8.0

    Result = Data.define(:delivered, :deferred, :failed, :needs_review)

    def initialize(outbox:, client:, store:, clock: -> { Time.now.utc }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: Kernel.method(:sleep), random: Random.new, inter_message_delay: 0.0)
      @outbox = outbox
      @client = client
      @store = store
      @clock = clock
      @monotonic_clock = monotonic_clock
      @sleeper = sleeper
      @random = random
      @inter_message_delay = inter_message_delay
    end

    def drain(channel:, budget: DRAIN_BUDGET)
      counts = { delivered: [], deferred: [], failed: [], needs_review: [] }
      locked = @outbox.try_drain_lock do
        deadline = monotonic_now + budget
        drain_jobs(channel.to_s, deadline, counts)
      end
      return Result.new(**counts) if locked

      counts[:deferred] = @outbox.jobs.select { |job| job['channel'] == channel.to_s }.map { |job| job['id'] }
      Result.new(**counts)
    end

    private

    def drain_jobs(channel, deadline, counts)
      immediate_attempts = Hash.new(0)
      loop do
        job = next_eligible_job(channel)
        break unless job
        break if monotonic_now >= deadline

        outcome = deliver_with_lock(job)
        if outcome == :delivered
          @outbox.complete(job)
          counts[:delivered] << job['id']
          next
        end
      rescue SlackClient::Error => e
        immediate_attempts[job['id']] += 1
        disposition = handle_delivery_error(job, e, immediate_attempts[job['id']], deadline)
        next if disposition == :retry_now

        counts[disposition] << job['id'] unless counts[disposition].include?(job['id'])
        break if disposition == :deferred && blocking_head?(job)
      end
    end

    def next_eligible_job(channel)
      blocked = (@outbox.jobs(:failed) + @outbox.jobs(:needs_review)).map { |job| job['ordering_key'] }.uniq
      seen = {}
      @outbox.jobs.find do |job|
        key = job['ordering_key']
        next false if seen[key]

        seen[key] = true
        next false if blocked.include?(key) || job['channel'] != channel

        due?(job)
      end
    end

    def blocking_head?(job)
      @outbox.jobs.none? do |candidate|
        candidate['channel'] == job['channel'] && candidate['ordering_key'] != job['ordering_key'] && due?(candidate)
      end
    end

    def due?(job)
      value = job['next_attempt_at']
      value.nil? || Time.iso8601(value) <= now
    rescue ArgumentError
      true
    end

    def deliver_with_lock(job)
      @store.with_session_lock(job['ordering_key']) do
        current = @outbox.jobs.find { |candidate| candidate['id'] == job['id'] }
        return :delivered unless current

        job.replace(current)
        if @store.generation_for(job['ordering_key']) != job['generation'].to_i
          return :delivered
        end
        if job['resolved_thread_ts'] && job['action'] != 'standalone'
          @store.save_thread_ts(job['ordering_key'], job['resolved_thread_ts'])
        end

        deliver(job)
      end
    end

    def deliver(job)
      case job['phase']
      when 'pending'
        start_job(job)
      when 'posting_root', 'posting_recovery_root'
        post_root(job)
      when 'posting_root_remainder', 'posting_recovery_remainder'
        post_root_remainder(job)
      when 'posting_message'
        post_message(job)
      else
        raise SlackOutbox::Error, "unknown outbox phase: #{job['phase']}"
      end
    rescue SlackClient::Error => e
      stale = e.stale_thread? || STALE_THREAD_CODES.include?(e.error_code)
      already_recovering = job['phase'].to_s.include?('recovery')
      root_not_created = job['phase'] == 'posting_root'
      raise unless stale && job['action'] != 'standalone' && !already_recovering && !root_not_created

      @store.clear_thread(job['ordering_key'])
      job['phase'] = 'posting_recovery_root'
      job['next_chunk'] = 0
      job['resolved_thread_ts'] = nil
      @outbox.update(job)
      deliver(job)
    end

    def start_job(job)
      case job['action']
      when 'standalone'
        transition(job, 'posting_root')
      when 'ensure_thread', 'root_or_reply'
        if (thread_ts = @store.thread_ts_for(job['ordering_key']))
          return :delivered if job['action'] == 'ensure_thread'

          job['resolved_thread_ts'] = thread_ts
          transition(job, 'posting_message')
        else
          transition(job, 'posting_root')
        end
      when 'reply'
        thread_ts = @store.thread_ts_for(job['ordering_key'])
        return :delivered unless thread_ts

        job['resolved_thread_ts'] = thread_ts
        transition(job, 'posting_message')
      else
        raise SlackOutbox::Error, "unknown outbox action: #{job['action']}"
      end
    end

    def post_root(job)
      chunks = root_chunks(job)
      return finish_root(job) if chunks.empty?

      response = post(chunks.fetch(0))
      job['resolved_thread_ts'] = response.fetch('ts').to_s
      job['next_chunk'] = 1
      job['phase'] = job['phase'] == 'posting_recovery_root' ? 'posting_recovery_remainder' : 'posting_root_remainder'
      @outbox.update(job)
      @store.save_thread_ts(job['ordering_key'], job['resolved_thread_ts']) unless job['action'] == 'standalone'
      deliver(job)
    end

    def post_root_remainder(job)
      chunks = root_chunks(job)
      while job['next_chunk'] < chunks.length
        post(chunks.fetch(job['next_chunk']), thread_ts: job['resolved_thread_ts'])
        job['next_chunk'] += 1
        @outbox.update(job)
      end
      finish_root(job)
    end

    def finish_root(job)
      if job['phase'].to_s.include?('recovery') && job['message_chunks'] != job['recovery_root_chunks']
        job['next_chunk'] = 0
        transition(job, 'posting_message')
      else
        :delivered
      end
    end

    def post_message(job)
      chunks = job['message_chunks']
      while job['next_chunk'] < chunks.length
        post(chunks.fetch(job['next_chunk']), thread_ts: job['resolved_thread_ts'])
        job['next_chunk'] += 1
        @outbox.update(job)
      end
      :delivered
    end

    def root_chunks(job)
      job['phase'].to_s.include?('recovery') ? job['recovery_root_chunks'] : job['message_chunks']
    end

    def transition(job, phase)
      job['phase'] = phase
      job['next_chunk'] = 0
      @outbox.update(job)
      deliver(job)
    end

    def post(text, thread_ts: nil)
      response = @client.post(text, thread_ts:)
      @sleeper.call(@inter_message_delay) if @inter_message_delay.positive?
      response
    end

    def handle_delivery_error(job, error, immediate_attempt, deadline)
      job['attempt_count'] += 1
      job['last_error'] = {
        'code' => error.error_code,
        'http_status' => error.http_status,
        'ambiguous' => error.ambiguous?
      }.compact

      unless error.retryable?
        @outbox.update(job)
        @outbox.move(job, :failed)
        return :failed
      end

      if error.ambiguous?
        job['ambiguous_attempt_count'] += 1
        @outbox.update(job)
        if job['ambiguous_attempt_count'] >= MAX_AMBIGUOUS_ATTEMPTS
          @outbox.move(job, :needs_review)
          return :needs_review
        end
        schedule(job, backoff(job['attempt_count']))
        return :deferred
      end

      delay = error.retry_after || backoff(job['attempt_count'])
      if immediate_attempt < MAX_IMMEDIATE_ATTEMPTS && monotonic_now + delay < deadline
        @sleeper.call(delay)
        job['next_attempt_at'] = nil
        @outbox.update(job)
        return :retry_now
      end

      schedule(job, delay)
      :deferred
    end

    def schedule(job, delay)
      job['next_attempt_at'] = (now + delay).iso8601
      @outbox.update(job)
    end

    def backoff(attempt)
      cap = [0.5 * (2**([attempt - 1, 0].max)), BACKOFF_CAP].min
      @random.rand * cap
    end

    def now = @clock.call.utc
    def monotonic_now = @monotonic_clock.call
  end
end
