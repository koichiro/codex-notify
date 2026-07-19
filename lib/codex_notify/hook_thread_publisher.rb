# frozen_string_literal: true

require_relative 'message_formatter'
require_relative 'slack_client'
require_relative 'durable_slack_publisher'

module CodexNotify
  class HookThreadPublisher
    STALE_THREAD_ERROR_CODES = %w[thread_not_found message_not_found invalid_ts].freeze

    def initialize(client:, store:, outbox: nil, channel: nil)
      @client = client
      @store = store
      @durable = DurableSlackPublisher.new(client:, store:, outbox:, channel:) if outbox
    end

    attr_reader :client

    def ensure_thread(session_id:, root_message:)
      return @durable.ensure_thread(key: session_id, root_message:) if @durable

      thread_ts = thread_for(session_id)
      return thread_ts if thread_ts

      create_thread(session_id:, root_message:)
    end

    def publish_root_or_reply(session_id:, message:)
      return @durable.publish_root_or_reply(key: session_id, message:) if @durable

      thread_ts = thread_for(session_id)
      return create_thread(session_id:, root_message: message) unless thread_ts

      begin
        post_message(message, thread_ts:)
        thread_ts
      rescue SlackClient::Error => e
        raise unless stale_thread_error?(e)

        reset_thread(session_id:)
        create_thread(session_id:, root_message: message)
      end
    end

    def publish_reply(session_id:, message:, recovery_root_message:)
      if @durable
        return @durable.publish_reply(key: session_id, message:, recovery_root_message:)
      end

      thread_ts = thread_for(session_id)
      return unless thread_ts

      begin
        post_message(message, thread_ts:)
        thread_ts
      rescue SlackClient::Error => e
        raise unless stale_thread_error?(e)

        reset_thread(session_id:)
        recovered_thread_ts = create_thread(session_id:, root_message: recovery_root_message)
        return unless recovered_thread_ts

        post_message(message, thread_ts: recovered_thread_ts)
        recovered_thread_ts
      end
    end

    def reset_thread(session_id:)
      return @durable.reset(key: session_id) if @durable

      @store.clear_thread(session_id)
    end

    def drain
      @durable&.drain
    end

    private

    def thread_for(session_id)
      @store.thread_ts_for(session_id)
    end

    def create_thread(session_id:, root_message:)
      return if root_message.nil? || root_message.body.empty?

      parts = MessageFormatter.chunks(root_message).to_a
      response = @client.post(parts.shift)
      thread_ts = response.fetch('ts').to_s
      @store.save_thread_ts(session_id, thread_ts)
      post_parts(parts, thread_ts:)
      thread_ts
    end

    def post_message(message, thread_ts:)
      post_parts(MessageFormatter.chunks(message), thread_ts:)
    end

    def post_parts(parts, thread_ts:)
      parts.each { |part| @client.post(part, thread_ts:) }
    end

    def stale_thread_error?(error)
      STALE_THREAD_ERROR_CODES.include?(error.error_code)
    end
  end
end
