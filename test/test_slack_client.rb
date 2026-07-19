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

  private

  def with_captured_http_request
    requests = []
    original = Net::HTTP.method(:start)
    original_verbose = $VERBOSE
    $VERBOSE = nil
    Net::HTTP.singleton_class.send(:define_method, :start) do |*, **, &block|
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        Struct.new(:body).new('{"ok":true,"ts":"1000.01"}')
      end
      block.call(http)
    end

    yield requests
  ensure
    Net::HTTP.singleton_class.send(:define_method, :start, original)
    $VERBOSE = original_verbose
  end
end
