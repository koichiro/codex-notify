# frozen_string_literal: true

require 'json'
require 'pathname'
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

    private

    def state
      return default_state unless @path.exist?

      JSON.parse(@path.read)
    rescue JSON::ParserError
      default_state
    end

    def default_state
      { 'threads' => {} }
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
