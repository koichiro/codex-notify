# frozen_string_literal: true

require_relative 'codex_notify/log_event_parser'
require_relative 'codex_notify/message_formatter'
require_relative 'codex_notify/cli'

module CodexNotify
  def self.main(*args, **kwargs)
    CLI.main(*args, **kwargs)
  end
end
