# frozen_string_literal: true

require_relative 'hook_config'
require_relative 'hook_store'
require_relative 'hook_formatter'
require_relative 'hook_thread_publisher'
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
      @store = HookStore.new(state_file)
      client = SlackClient.new(token:, channel:)
      @publisher = HookThreadPublisher.new(client:, store: @store)
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

    def session_root_message(event)
      title = @title || "Codex session: #{File.basename(event.cwd)}"
      HookFormatter.session_root_message(event, title:, user_name: @user_name)
    end

    def handle_session_start(event)
      if reset_thread_on_session_start?(event)
        session_id = event.session_id
        @publisher.reset_thread(session_id:)
        @store.clear_suppressed_session(session_id)
      end
      @publisher.ensure_thread(session_id: event.session_id, root_message: session_root_message(event)) if debug?
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
        @publisher.reset_thread(session_id:)
        return
      end

      message = HookFormatter.prompt_message(event, user_name: @user_name)
      @publisher.publish_root_or_reply(session_id:, message:)
    end

    def handle_pre_tool_use(event)
      return unless debug?

      @publisher.publish_reply(
        session_id: event.session_id,
        message: HookFormatter.pre_tool_message(event),
        recovery_root_message: session_root_message(event)
      )
    end

    def handle_post_tool_use(event)
      return unless debug?

      @publisher.publish_reply(
        session_id: event.session_id,
        message: HookFormatter.post_tool_message(event),
        recovery_root_message: session_root_message(event)
      )
    end

    def handle_permission_request(event)
      message = HookFormatter.permission_request_message(event)
      @publisher.publish_root_or_reply(session_id: event.session_id, message:)
    end

    def handle_stop(event)
      session_id = event.session_id
      return if normal? && @store.suppressed_session?(session_id)

      message = event.assistant_message
      return if normal? && internal_ambient_suggestions_response?(message)

      unless message.nil? || message.to_s.empty?
        @publisher.publish_reply(
          session_id:,
          message: HookFormatter.assistant_message(event),
          recovery_root_message: session_root_message(event)
        )
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
