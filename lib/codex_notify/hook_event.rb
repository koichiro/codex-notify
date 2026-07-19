# frozen_string_literal: true

module CodexNotify
  HookEvent = Data.define(
    :name,
    :session_id,
    :cwd,
    :source,
    :prompt,
    :tool_name,
    :tool_input,
    :tool_response,
    :assistant_message,
    :raw_payload
  )
end
