# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'
require_relative 'test_helper'

class CodexNotifySecretProtectionTest < Minitest::Test
  SecretProtection = CodexNotify::SecretProtection

  def test_redacts_structured_secrets_and_known_token_formats
    text = <<~TEXT
      SLACK_BOT_TOKEN=xoxb-super-secret
      password: "correct horse battery staple"
      {"api_key":"sk-abcdefghijklmnop"}
      Authorization: Bearer bearer-value
      HTTP_AUTHORIZATION=Bearer environment-bearer-value
      curl --token ghp_abcdefghijklmnopqrstuvwxyz
      AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
    TEXT

    redacted = SecretProtection.redact(text)

    assert_equal 7, redacted.scan(SecretProtection::REDACTED).size
    refute_includes redacted, 'super-secret'
    refute_includes redacted, 'correct horse'
    refute_includes redacted, 'bearer-value'
    refute_includes redacted, 'environment-bearer-value'
    refute_includes redacted, 'ghp_abcdefghijklmnopqrstuvwxyz'
  end

  def test_redaction_preserves_non_secret_text
    text = "token count: 42\nbundle exec rake\nrequest completed"

    assert_equal text, SecretProtection.redact(text)
  end

  def test_warns_when_env_file_is_group_or_world_readable
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.env')
      File.write(path, "SLACK_BOT_TOKEN=xoxb-secret\n")
      File.chmod(0o644, path)
      stderr = StringIO.new

      SecretProtection.warn_if_env_file_insecure(path, stderr:)

      assert_includes stderr.string, 'permissions 0644'
      assert_includes stderr.string, "chmod 600 #{path}"
    end
  end

  def test_does_not_warn_when_env_file_is_owner_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.env')
      File.write(path, "SLACK_BOT_TOKEN=xoxb-secret\n")
      File.chmod(0o600, path)
      stderr = StringIO.new

      SecretProtection.warn_if_env_file_insecure(path, stderr:)

      assert_empty stderr.string
    end
  end

  def test_slack_client_redacts_at_send_boundary
    with_captured_http_request do |requests|
      CodexNotify::SlackClient.new(token: 'transport-token', channel: 'C123')
                              .post('result: SLACK_BOT_TOKEN=xoxb-leaked-value')

      payload = JSON.parse(requests.fetch(0).body)
      assert_includes payload.fetch('text'), SecretProtection::REDACTED
      refute_includes payload.fetch('text'), 'xoxb-leaked-value'
    end
  end

  def test_log_tail_client_redacts_at_send_boundary
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
