# frozen_string_literal: true

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
end
