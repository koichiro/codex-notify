# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module CodexNotify
  class SlackClient
    class Error < StandardError
      attr_reader :response, :error_code

      def initialize(message, response: nil, error_code: nil)
        super(message)
        @response = response
        @error_code = error_code
      end
    end

    SLACK_API = 'https://slack.com/api/chat.postMessage'

    def initialize(token:, channel:)
      @token = token
      @channel = channel
    end

    def post(text, thread_ts: nil)
      payload = { channel: @channel, text: text }
      payload[:thread_ts] = thread_ts.to_s if thread_ts

      uri = URI(SLACK_API)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{@token}"
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 20) do |http|
        http.request(request)
      end

      parsed = JSON.parse(response.body)
      unless parsed['ok']
        raise Error.new("Slack API error: #{parsed}", response: parsed, error_code: parsed['error'])
      end

      parsed
    end
  end
end
