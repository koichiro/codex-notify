# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'hook_store'
require_relative 'hook_formatter'
require_relative 'slack_client'

module CodexNotify
  class HookRunner
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
      else
        @stdout.puts(JSON.generate({ continue: true }))
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

    def ensure_session_thread(payload)
      session_id = session_id_from(payload) || '__default__'
      thread_ts = thread_for(session_id)
      return [session_id, thread_ts] if thread_ts

      cwd = cwd_from(payload)
      title = @title || "Codex session: #{File.basename(cwd)}"
      root_text = HookFormatter.session_root_text(
        title: title,
        cwd: cwd,
        session_id: session_id,
        user_name: @user_name
      )
      response = @client.post(root_text)
      thread_ts = response.fetch('ts').to_s
      @store.save_thread_ts(session_id, thread_ts)
      [session_id, thread_ts]
    end

    def handle_session_start(payload)
      ensure_session_thread(payload)
      @stdout.puts(JSON.generate({ continue: true }))
    end

    def handle_user_prompt_submit(payload)
      _session_id, thread_ts = ensure_session_thread(payload)
      prompt = payload['prompt'] || payload.dig('payload', 'prompt')
      unless prompt.nil? || prompt.to_s.empty?
        @client.post(HookFormatter.prompt_text(user_name: @user_name, prompt: prompt), thread_ts: thread_ts)
      end
      @stdout.puts(JSON.generate({ continue: true }))
    end

    def handle_pre_tool_use(payload)
      _session_id, thread_ts = ensure_session_thread(payload)
      @client.post(HookFormatter.format_pre_tool(payload), thread_ts: thread_ts)
      @stdout.puts(JSON.generate({ continue: true }))
    end

    def handle_post_tool_use(payload)
      _session_id, thread_ts = ensure_session_thread(payload)
      @client.post(HookFormatter.format_post_tool(payload), thread_ts: thread_ts)
      @stdout.puts(JSON.generate({ continue: true }))
    end

    def handle_stop(payload)
      _session_id, thread_ts = ensure_session_thread(payload)
      message = payload['last_assistant_message'] || payload.dig('payload', 'last_assistant_message')
      unless message.nil? || message.to_s.empty?
        @client.post(HookFormatter.assistant_text(message), thread_ts: thread_ts)
      end
      @stdout.puts(JSON.generate({ continue: true }))
    end
  end
end
