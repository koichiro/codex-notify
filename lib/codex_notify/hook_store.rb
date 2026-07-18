# frozen_string_literal: true

require 'json'
require 'pathname'
require 'time'
require 'tmpdir'

module CodexNotify
  class HookStore
    def initialize(path)
      @path = Pathname(path)
    end

    def thread_ts_for(session_id)
      state.dig('threads', session_id.to_s)
    end

    def save_thread_ts(session_id, thread_ts)
      update_state do |data|
        data['threads'][session_id.to_s] = thread_ts.to_s
      end
    end

    def clear_thread(session_id)
      update_state do |data|
        data['threads'].delete(session_id.to_s)
      end
    end

    def suppress_session(session_id, reason)
      update_state do |data|
        key = session_id.to_s
        data['threads'].delete(key)
        data['suppressed_sessions'][key] = {
          'reason' => reason.to_s,
          'suppressed_at' => Time.now.utc.iso8601
        }
      end
    end

    def suppressed_session?(session_id)
      state.fetch('suppressed_sessions', {}).key?(session_id.to_s)
    end

    def clear_suppressed_session(session_id)
      update_state do |data|
        data['suppressed_sessions'].delete(session_id.to_s)
      end
    end

    private

    def state
      return default_state unless @path.exist?

      normalize_state(JSON.parse(@path.read))
    rescue JSON::ParserError
      default_state
    end

    def default_state
      { 'threads' => {}, 'suppressed_sessions' => {} }
    end

    def normalize_state(data)
      data = {} unless data.is_a?(Hash)
      defaults = default_state
      defaults.merge(data) do |_key, default_value, value|
        value.is_a?(Hash) ? value : default_value
      end
    end

    def update_state
      data = state
      yield(data)
      write_state(data)
    end

    def write_state(data)
      @path.dirname.mkpath
      tmp = @path.dirname.join(".#{@path.basename}.tmp-#{Process.pid}")
      tmp.write(JSON.pretty_generate(data))
      File.rename(tmp, @path)
    ensure
      tmp.delete if defined?(tmp) && tmp.exist?
    end
  end
end
