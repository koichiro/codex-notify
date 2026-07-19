# frozen_string_literal: true

require 'json'
require_relative 'test_helper'

class CodexNotifySlackClientTest < Minitest::Test
  SecretProtection = CodexNotify::SecretProtection

  def test_redacts_at_send_boundary
    with_captured_http_request do |requests|
      CodexNotify::SlackClient.new(token: 'transport-token', channel: 'C123')
                              .post('result: SLACK_BOT_TOKEN=xoxb-leaked-value')

      payload = JSON.parse(requests.fetch(0).body)
      assert_includes payload.fetch('text'), SecretProtection::REDACTED
      refute_includes payload.fetch('text'), 'xoxb-leaked-value'
    end
  end

  def test_log_tail_posts_through_the_redacting_client
    with_captured_http_request do |requests|
      CodexNotify::CLI.slack_post('transport-token', 'C123', 'Authorization: Bearer leaked-value')

      payload = JSON.parse(requests.fetch(0).body)
      assert_equal "Authorization: #{SecretProtection::REDACTED}", payload.fetch('text')
    end
  end

  def test_classifies_rate_limit_and_retry_after
    response = http_response('429', '{"ok":false,"error":"ratelimited"}', 'Retry-After' => '7')
    with_captured_http_request(response:) do
      error = assert_raises(CodexNotify::SlackClient::Error) do
        CodexNotify::SlackClient.new(token: 'token', channel: 'C123').post('message')
      end

      assert error.retryable?
      refute error.ambiguous?
      assert_equal 429, error.http_status
      assert_equal 7, error.retry_after
    end
  end

  def test_classifies_server_error_as_ambiguous
    with_captured_http_request(response: http_response('503', 'unavailable')) do
      error = assert_raises(CodexNotify::SlackClient::Error) do
        CodexNotify::SlackClient.new(token: 'token', channel: 'C123').post('message')
      end

      assert error.retryable?
      assert error.ambiguous?
      assert_equal 503, error.http_status
    end
  end

  def test_classifies_stale_thread_api_error
    body = '{"ok":false,"error":"thread_not_found"}'
    with_captured_http_request(response: http_response('200', body)) do
      error = assert_raises(CodexNotify::SlackClient::Error) do
        CodexNotify::SlackClient.new(token: 'token', channel: 'C123').post('message', thread_ts: 'old')
      end

      assert error.stale_thread?
      refute error.retryable?
      assert_equal 'thread_not_found', error.error_code
    end
  end

  private

  def with_captured_http_request(response: Struct.new(:body).new('{"ok":true,"ts":"1000.01"}'))
    requests = []
    original = Net::HTTP.method(:start)
    original_verbose = $VERBOSE
    $VERBOSE = nil
    Net::HTTP.singleton_class.send(:define_method, :start) do |*, **, &block|
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        response
      end
      block.call(http)
    end

    yield requests
  ensure
    Net::HTTP.singleton_class.send(:define_method, :start, original)
    $VERBOSE = original_verbose
  end

  def http_response(code, body, headers = {})
    Struct.new(:code, :body, :headers) do
      def [](name) = headers[name]
    end.new(code, body, headers)
  end
end
