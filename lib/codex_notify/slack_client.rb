# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'secret_protection'

module CodexNotify
  class SlackClient
    class Error < StandardError
      attr_reader :response, :error_code, :http_status, :retry_after

      def initialize(message, response: nil, error_code: nil, http_status: nil, retry_after: nil,
                     retryable: false, ambiguous: false, stale_thread: false)
        super(message)
        @response = response
        @error_code = error_code
        @http_status = http_status
        @retry_after = retry_after
        @retryable = retryable
        @ambiguous = ambiguous
        @stale_thread = stale_thread
      end

      def retryable? = @retryable
      def ambiguous? = @ambiguous
      def stale_thread? = @stale_thread
    end

    SLACK_API = 'https://slack.com/api/chat.postMessage'
    OPEN_TIMEOUT = 5
    WRITE_TIMEOUT = 10
    READ_TIMEOUT = 20
    RETRYABLE_CODES = %w[ratelimited rate_limited internal_error fatal_error service_unavailable request_timeout].freeze
    AMBIGUOUS_CODES = %w[internal_error fatal_error service_unavailable request_timeout].freeze
    STALE_THREAD_CODES = %w[thread_not_found message_not_found invalid_ts].freeze

    def initialize(token:, channel:)
      @token = token
      @channel = channel
    end

    def post(text, thread_ts: nil)
      payload = { channel: @channel, text: SecretProtection.redact(text) }
      payload[:thread_ts] = thread_ts.to_s if thread_ts

      uri = URI(SLACK_API)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{@token}"
      request.body = JSON.generate(payload)

      request_started = false
      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: true,
        open_timeout: OPEN_TIMEOUT,
        write_timeout: WRITE_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) do |http|
        request_started = true
        http.request(request)
      end

      status = response.respond_to?(:code) ? response.code.to_i : 200
      retry_after = parse_retry_after(response_header(response, 'Retry-After'))
      if status == 429
        raise build_error('Slack rate limited request', http_status: status, retry_after:, retryable: true)
      end
      if status >= 500
        raise build_error('Slack server error', http_status: status, retryable: true, ambiguous: true)
      end

      parsed = JSON.parse(response.body.to_s)
      unless parsed['ok']
        code = parsed['error'].to_s
        raise build_error(
          "Slack API error: #{code.empty? ? 'unknown' : code}",
          response: parsed,
          error_code: code,
          retry_after:,
          retryable: RETRYABLE_CODES.include?(code),
          ambiguous: AMBIGUOUS_CODES.include?(code),
          stale_thread: STALE_THREAD_CODES.include?(code)
        )
      end

      parsed
    rescue Net::OpenTimeout, SocketError => e
      raise build_error("Slack connection failed: #{e.class}", retryable: true)
    rescue OpenSSL::SSL::SSLError, SystemCallError => e
      raise build_error("Slack connection failed: #{e.class}", retryable: true, ambiguous: request_started)
    rescue Net::WriteTimeout, Net::ReadTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
      raise build_error("Slack request outcome is unknown: #{e.class}", retryable: true, ambiguous: request_started)
    rescue JSON::ParserError
      raise build_error('Slack returned an invalid JSON response', retryable: true, ambiguous: true)
    end

    private

    def build_error(message, **attributes)
      Error.new(message, **attributes)
    end

    def parse_retry_after(value)
      seconds = Integer(value, exception: false)
      seconds if seconds && seconds >= 0
    end

    def response_header(response, name)
      response[name] if response.respond_to?(:[])
    rescue NameError, IndexError
      nil
    end
  end
end
