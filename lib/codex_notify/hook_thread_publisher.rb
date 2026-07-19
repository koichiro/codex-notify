# frozen_string_literal: true

require_relative 'message_formatter'
require_relative 'slack_client'

module CodexNotify
  class HookThreadPublisher
    STALE_THREAD_ERROR_CODES = %w[thread_not_found message_not_found invalid_ts].freeze

    def initialize(client:, store:)
      @client = client
      @store = store
    end

    def ensure_thread(session_id:, root_text:)
      thread_ts = thread_for(session_id)
      return thread_ts if thread_ts

      create_thread(session_id:, root_text:)
    end

    def publish_root_or_reply(session_id:, text:)
      thread_ts = thread_for(session_id)
      return create_thread(session_id:, root_text: text) unless thread_ts

      begin
        post_text(text, thread_ts:)
        thread_ts
      rescue SlackClient::Error => e
        raise unless stale_thread_error?(e)

        reset_thread(session_id:)
        create_thread(session_id:, root_text: text)
      end
    end

    def publish_reply(session_id:, text:, recovery_root_text:)
      thread_ts = thread_for(session_id)
      return unless thread_ts

      begin
        post_text(text, thread_ts:)
        thread_ts
      rescue SlackClient::Error => e
        raise unless stale_thread_error?(e)

        reset_thread(session_id:)
        recovered_thread_ts = create_thread(session_id:, root_text: recovery_root_text)
        return unless recovered_thread_ts

        post_text(text, thread_ts: recovered_thread_ts)
        recovered_thread_ts
      end
    end

    def reset_thread(session_id:)
      @store.clear_thread(session_id)
    end

    private

    def thread_for(session_id)
      @store.thread_ts_for(session_id)
    end

    def create_thread(session_id:, root_text:)
      return if root_text.nil? || root_text.to_s.empty?

      parts = MessageFormatter.chunk_text(root_text).to_a
      response = @client.post(parts.shift)
      thread_ts = response.fetch('ts').to_s
      @store.save_thread_ts(session_id, thread_ts)
      post_parts(parts, thread_ts:)
      thread_ts
    end

    def post_text(text, thread_ts:)
      post_parts(MessageFormatter.chunk_text(text), thread_ts:)
    end

    def post_parts(parts, thread_ts:)
      parts.each { |part| @client.post(part, thread_ts:) }
    end

    def stale_thread_error?(error)
      STALE_THREAD_ERROR_CODES.include?(error.error_code)
    end
  end
end
