# frozen_string_literal: true

require 'digest'
require_relative 'message_formatter'
require_relative 'slack_delivery_worker'

module CodexNotify
  class DurableSlackPublisher
    def initialize(client:, store:, outbox:, channel:, throttle_sec: 0.0)
      @store = store
      @outbox = outbox
      @channel = channel
      @worker = SlackDeliveryWorker.new(outbox:, client:, store:, inter_message_delay: throttle_sec)
      @queued_ids = []
    end

    attr_reader :queued_ids

    def publish_standalone(key:, message:)
      enqueue(key:, action: :standalone, message:)
    end

    def ensure_thread(key:, root_message:)
      return if @store.thread_ts_for(key)
      return if @outbox.pending_root?(key, generation: @store.generation_for(key))

      enqueue(key:, action: :ensure_thread, message: root_message)
    end

    def publish_root_or_reply(key:, message:)
      enqueue(key:, action: :root_or_reply, message:, recovery_root_message: message)
    end

    def publish_reply(key:, message:, recovery_root_message:)
      has_root = @store.thread_ts_for(key) || @outbox.pending_root?(key, generation: @store.generation_for(key))
      return unless has_root

      enqueue(key:, action: :reply, message:, recovery_root_message: recovery_root_message || message)
    end

    def reset(key:)
      @store.advance_generation(key)
    end

    def drain
      @worker.drain(channel: @channel)
    end

    def key(namespace, identity)
      Digest::SHA256.hexdigest("#{namespace}\0#{identity}")
    end

    private

    def enqueue(key:, action:, message:, recovery_root_message: nil)
      chunks = message ? MessageFormatter.chunks(message).to_a : []
      recovery_chunks = recovery_root_message ? MessageFormatter.chunks(recovery_root_message).to_a : []
      id = @outbox.enqueue(
        channel: @channel,
        ordering_key: key,
        generation: @store.generation_for(key),
        action:,
        chunks:,
        recovery_chunks:
      )
      @queued_ids << id
      id
    end
  end
end
