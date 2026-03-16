# frozen_string_literal: true

require 'pathname'

module CodexNotify
  module SessionLog
    module_function

    def iter_follow_lines(path, poll_sec: 1.0, once: false, start_at_end: true, sleep_func: Kernel.method(:sleep))
      return enum_for(__method__, path, poll_sec:, once:, start_at_end:, sleep_func:) unless block_given?

      Pathname(path).open('r:utf-8') do |handle|
        handle.seek(0, IO::SEEK_END) if start_at_end
        loop do
          line = handle.gets
          if line
            yield line
            next
          end
          break if once

          sleep_func.call(poll_sec)
        end
      end
    end

    def find_latest_session_file(sessions_dir)
      root = Pathname(sessions_dir)
      return nil unless root.exist?

      files = root.glob('**/*.jsonl').select(&:file?)
      return nil if files.empty?

      files.max_by { |path| path.stat.mtime.to_f }
    end

    def session_id_from_path(path)
      pathname = Pathname(path)
      pathname.basename('.jsonl').to_s
    end
  end
end
