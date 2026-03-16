# frozen_string_literal: true

module CodexNotify
  module MessageFormatter
    module_function

    def chunk_text(text, max_len = 3500)
      normalized = text.gsub("\r\n", "\n")
      return enum_for(__method__, normalized, max_len) unless block_given?

      index = 0
      while index < normalized.length
        yield normalized[index, max_len]
        index += max_len
      end
    end

    def fmt_block(title, body)
      "*#{title}*\n```#{body}```"
    end

    def build_root_text(title, cwd, user_name: 'user', session_id: nil)
      body = [
        'Codex log monitoring started.',
        "CWD: #{cwd}",
        "User: #{user_name}",
        "Session ID: #{session_id || 'unknown'}"
      ].join("\n")
      fmt_block(title, body)
    end

    def fmt_plain(title, body)
      "*#{title}*\n#{body}"
    end
  end
end
