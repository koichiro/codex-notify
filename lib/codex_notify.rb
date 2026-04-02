# frozen_string_literal: true

require_relative 'codex_notify/log_event_parser'
require_relative 'codex_notify/message_formatter'
require_relative 'codex_notify/session_log'
require_relative 'codex_notify/stream_processor'
require_relative 'codex_notify/config'
require_relative 'codex_notify/cli'
require_relative 'codex_notify/slack_client'
require_relative 'codex_notify/hook_config'
require_relative 'codex_notify/hook_store'
require_relative 'codex_notify/hook_formatter'
require_relative 'codex_notify/hook_runner'
require_relative 'codex_notify/hook_cli'

module CodexNotify
  def self.main(*args, **kwargs)
    CLI.main(*args, **kwargs)
  end
end
