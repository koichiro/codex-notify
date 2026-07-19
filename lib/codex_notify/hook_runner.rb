# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'hook_config'
require_relative 'hook_store'
require_relative 'hook_formatter'
require_relative 'message_formatter'
require_relative 'slack_client'

module CodexNotify
  class HookRunner
    RESET_THREAD_PROMPT = '---'
    SESSION_RESET_SOURCES = %w[startup clear].freeze
    INTERNAL_AMBIENT_SUGGESTIONS_PROMPTS = [
      [
        '# Overview',
        'Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project',
        "Suggest actionable tasks that they would actually act on/click"
      ].freeze,
      [
        'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.',
        'ambient suggestion candidates',
        '## 1. Policies to always exclude'
      ].freeze
    ].freeze
    INTERNAL_AMBIENT_SUGGESTIONS_RESPONSES = [
      [
        'exclude',
        'suggestion_id',
        'Only output the JSON object'
      ].freeze,
      [
        'suggestions to exclude',
        'reason',
        'applicable policy'
      ].freeze
    ].freeze

    def initialize(token:, channel:, user_name:, title:, state_file:, mode: HookConfig::DEFAULT_MODE, stdout: $stdout)
      @client = SlackClient.new(token:, channel:)
      @store = HookStore.new(state_file)
      @user_name = user_name
      @title = title
      @mode = mode
      @stdout = stdout
    end

    def run(event:)
      @store.with_session_lock(event.session_id) do
        case event.name
        when 'SessionStart'
          handle_session_start(event)
        when 'UserPromptSubmit'
          handle_user_prompt_submit(event)
        when 'PreToolUse'
          handle_pre_tool_use(event)
        when 'PostToolUse'
          handle_post_tool_use(event)
        when 'PermissionRequest'
          handle_permission_request(event)
        when 'Stop'
          handle_stop(event)
        end
      end

      0
    end

    private

    def thread_for(session_id)
      @store.thread_ts_for(session_id)
    end

    def session_root_text(event)
      title = @title || "Codex session: #{File.basename(event.cwd)}"
      HookFormatter.session_root_text(event, title:, user_name: @user_name)
    end

    def ensure_session_thread(event, root_text: nil)
      session_id = event.session_id
      thread_ts = thread_for(session_id)
      return [session_id, thread_ts, false] if thread_ts

      return [session_id, nil, false] if root_text.nil? || root_text.to_s.empty?

      parts = MessageFormatter.chunk_text(root_text).to_a
      response = @client.post(parts.shift)
      thread_ts = response.fetch('ts').to_s
      @store.save_thread_ts(session_id, thread_ts)
      post_parts(parts, thread_ts:)
      [session_id, thread_ts, true]
    end

    def stale_thread_error?(error)
      return false unless error.is_a?(SlackClient::Error)

      %w[thread_not_found message_not_found invalid_ts].include?(error.error_code)
    end

    def post_with_thread_recovery(event, text, fallback_root_text:)
      session_id = event.session_id
      thread_ts = thread_for(session_id)
      return if thread_ts.nil?

      post_parts(MessageFormatter.chunk_text(text), thread_ts:)
    rescue SlackClient::Error => e
      raise unless stale_thread_error?(e)

      @store.clear_thread(session_id)
      _session_id, recovered_thread_ts, = ensure_session_thread(event, root_text: fallback_root_text)
      return if recovered_thread_ts.nil?
      return if fallback_root_text == text

      post_parts(MessageFormatter.chunk_text(text), thread_ts: recovered_thread_ts)
    end

    def post_parts(parts, thread_ts:)
      parts.each { |part| @client.post(part, thread_ts:) }
    end

    def handle_session_start(event)
      if reset_thread_on_session_start?(event)
        session_id = event.session_id
        @store.clear_thread(session_id)
        @store.clear_suppressed_session(session_id)
      end
      ensure_session_thread(event, root_text: session_root_text(event)) if debug?
    end

    def handle_user_prompt_submit(event)
      prompt = event.prompt
      session_id = event.session_id
      if normal? && internal_ambient_suggestions_prompt?(prompt)
        @store.suppress_session(session_id, 'internal_ambient_suggestions')
        return
      end

      @store.clear_suppressed_session(session_id)

      if reset_thread_prompt?(prompt)
        @store.clear_thread(session_id)
        return
      end

      prompt_text = HookFormatter.prompt_text(event, user_name: @user_name)
      _session_id, thread_ts, created = ensure_session_thread(event, root_text: prompt_text)
      return if thread_ts.nil?
      return if created

      post_with_thread_recovery(event, prompt_text, fallback_root_text: prompt_text)
    end

    def handle_pre_tool_use(event)
      return unless debug?

      _session_id, thread_ts, = ensure_session_thread(event)
      return if thread_ts.nil?

      post_with_thread_recovery(event, HookFormatter.format_pre_tool(event), fallback_root_text: session_root_text(event))
    end

    def handle_post_tool_use(event)
      return unless debug?

      _session_id, thread_ts, = ensure_session_thread(event)
      return if thread_ts.nil?

      post_with_thread_recovery(event, HookFormatter.format_post_tool(event), fallback_root_text: session_root_text(event))
    end

    def handle_permission_request(event)
      text = HookFormatter.format_permission_request(event)
      _session_id, thread_ts, created = ensure_session_thread(event, root_text: text)
      return if thread_ts.nil? || created

      post_with_thread_recovery(event, text, fallback_root_text: text)
    end

    def handle_stop(event)
      session_id = event.session_id
      return if normal? && @store.suppressed_session?(session_id)

      message = event.assistant_message
      return if normal? && internal_ambient_suggestions_response?(message)

      _session_id, thread_ts, = ensure_session_thread(event)
      return if thread_ts.nil?

      unless message.nil? || message.to_s.empty?
        post_with_thread_recovery(event, HookFormatter.assistant_text(event), fallback_root_text: session_root_text(event))
      end
    end

    def reset_thread_prompt?(prompt)
      prompt.to_s.strip == RESET_THREAD_PROMPT
    end

    def reset_thread_on_session_start?(event)
      SESSION_RESET_SOURCES.include?(event.source.to_s)
    end

    def internal_ambient_suggestions_prompt?(prompt)
      text = prompt.to_s
      INTERNAL_AMBIENT_SUGGESTIONS_PROMPTS.any? do |markers|
        markers.all? { |marker| text.include?(marker) }
      end
    end

    def internal_ambient_suggestions_response?(message)
      text = message.to_s
      return false if text.empty?

      INTERNAL_AMBIENT_SUGGESTIONS_RESPONSES.any? do |markers|
        markers.all? { |marker| text.include?(marker) }
      end
    end

    def normal?
      @mode == 'normal'
    end

    def debug?
      @mode == 'debug'
    end
  end
end
