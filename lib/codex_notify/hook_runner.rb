# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'hook_store'
require_relative 'hook_formatter'
require_relative 'slack_client'

module CodexNotify
  class HookRunner
    RESET_THREAD_PROMPT = '---'

    EVENT_ALIASES = {
      'userpromptsubmit' => 'UserPromptSubmit',
      'pretooluse' => 'PreToolUse',
      'posttooluse' => 'PostToolUse',
      'stop' => 'Stop',
      'sessionstart' => 'SessionStart'
    }.freeze

    def initialize(token:, channel:, user_name:, title:, state_file:, stdout: $stdout)
      @client = SlackClient.new(token:, channel:)
      @store = HookStore.new(state_file)
      @user_name = user_name
      @title = title
      @stdout = stdout
    end

    def run(event_name:, payload:)
      normalized_event = normalize_event_name(event_name || payload['hook_event_name'] || payload['event'])

      case normalized_event
      when 'SessionStart'
        handle_session_start(payload)
      when 'UserPromptSubmit'
        handle_user_prompt_submit(payload)
      when 'PreToolUse'
        handle_pre_tool_use(payload)
      when 'PostToolUse'
        handle_post_tool_use(payload)
      when 'Stop'
        handle_stop(payload)
      end

      0
    end

    private

    def normalize_event_name(name)
      return nil if name.nil?

      text = name.to_s
      return text if EVENT_ALIASES.value?(text)

      EVENT_ALIASES[text.downcase.delete('_- ')] || text
    end

    def session_id_from(payload)
      value = payload['session_id'] || payload['sessionId'] || payload.dig('session', 'id')
      value.to_s unless value.nil? || value.to_s.empty?
    end

    def cwd_from(payload)
      payload['cwd'] || Dir.pwd
    end

    def thread_for(session_id)
      @store.thread_ts_for(session_id)
    end

    def session_root_text(payload)
      session_id = session_id_from(payload) || '__default__'
      cwd = cwd_from(payload)
      title = @title || "Codex session: #{File.basename(cwd)}"
      HookFormatter.session_root_text(title:, cwd:, session_id:, user_name: @user_name)
    end

    def ensure_session_thread(payload, root_text: nil)
      session_id = session_id_from(payload) || '__default__'
      thread_ts = thread_for(session_id)
      return [session_id, thread_ts, false] if thread_ts

      return [session_id, nil, false] if root_text.nil? || root_text.to_s.empty?

      response = @client.post(root_text)
      thread_ts = response.fetch('ts').to_s
      @store.save_thread_ts(session_id, thread_ts)
      [session_id, thread_ts, true]
    end

    def stale_thread_error?(error)
      return false unless error.is_a?(SlackClient::Error)

      %w[thread_not_found message_not_found invalid_ts].include?(error.error_code)
    end

    def post_with_thread_recovery(payload, text, fallback_root_text:)
      session_id = session_id_from(payload) || '__default__'
      thread_ts = thread_for(session_id)
      return if thread_ts.nil?

      @client.post(text, thread_ts: thread_ts)
    rescue SlackClient::Error => e
      raise unless stale_thread_error?(e)

      @store.clear_thread(session_id)
      _session_id, recovered_thread_ts, = ensure_session_thread(payload, root_text: fallback_root_text)
      return if recovered_thread_ts.nil?

      @client.post(text, thread_ts: recovered_thread_ts)
    end

    def handle_session_start(payload)
      ensure_session_thread(payload)
    end

    def handle_user_prompt_submit(payload)
      prompt = payload['prompt'] || payload.dig('payload', 'prompt')
      return if prompt.nil? || prompt.to_s.empty?

      session_id = session_id_from(payload) || '__default__'
      if reset_thread_prompt?(prompt)
        @store.clear_thread(session_id)
        return
      end

      prompt_text = HookFormatter.prompt_text(user_name: @user_name, prompt: prompt)
      _session_id, thread_ts, created = ensure_session_thread(payload, root_text: prompt_text)
      return if thread_ts.nil?
      return if created

      post_with_thread_recovery(payload, prompt_text, fallback_root_text: prompt_text)
    end

    def handle_pre_tool_use(payload)
      _session_id, thread_ts, = ensure_session_thread(payload)
      return if thread_ts.nil?

      post_with_thread_recovery(payload, HookFormatter.format_pre_tool(payload), fallback_root_text: session_root_text(payload))
    end

    def handle_post_tool_use(payload)
      _session_id, thread_ts, = ensure_session_thread(payload)
      return if thread_ts.nil?

      post_with_thread_recovery(payload, HookFormatter.format_post_tool(payload), fallback_root_text: session_root_text(payload))
    end

    def handle_stop(payload)
      _session_id, thread_ts, = ensure_session_thread(payload)
      return if thread_ts.nil?

      message = payload['last_assistant_message'] || payload.dig('payload', 'last_assistant_message')
      unless message.nil? || message.to_s.empty?
        post_with_thread_recovery(payload, HookFormatter.assistant_text(message), fallback_root_text: session_root_text(payload))
      end
    end

    def reset_thread_prompt?(prompt)
      prompt.to_s.strip == RESET_THREAD_PROMPT
    end
  end
end
