# frozen_string_literal: true

module CodexNotify
  module MessageFormatter
    SLACK_SAFE_LENGTH = 3500
    CONTINUATION_LABEL = '(cont.)'
    PRESENTATIONS = %i[plain block].freeze
    Message = Data.define(:title, :body, :presentation)

    module_function

    def message(title:, body:, presentation:)
      unless PRESENTATIONS.include?(presentation)
        raise ArgumentError, "unsupported message presentation: #{presentation.inspect}"
      end

      Message.new(
        title: title.to_s.dup.freeze,
        body: body.to_s.dup.freeze,
        presentation:
      )
    end

    def chunks(message, max_length: SLACK_SAFE_LENGTH)
      return enum_for(__method__, message, max_length:) unless block_given?

      validate_max_length(max_length, message.presentation)
      body = message.body.gsub("\r\n", "\n")
      index = 0
      chunk_index = 0

      loop do
        title = fit_title(
          message.title,
          message.presentation,
          max_length,
          body.empty?,
          continuation: chunk_index.positive?
        )
        capacity = max_length - render(title, '', message.presentation).length
        part = body[index, capacity] || ''
        yield render(title, part, message.presentation)

        index += part.length
        break if index >= body.length

        chunk_index += 1
      end
    end

    def fmt_block(title, body)
      render(title.to_s, body.to_s, :block)
    end

    def build_root_message(title, cwd, user_name: 'user', session_id: nil)
      body = root_body(cwd, user_name:, session_id:)
      message(title:, body:, presentation: :block)
    end

    def build_root_text(title, cwd, user_name: 'user', session_id: nil)
      fmt_block(title, root_body(cwd, user_name:, session_id:))
    end

    def fmt_plain(title, body)
      render(title.to_s, body.to_s, :plain)
    end

    def root_body(cwd, user_name:, session_id:)
      [
        'Codex log monitoring started.',
        "CWD: #{cwd}",
        "User: #{user_name}",
        "Session ID: #{session_id || 'unknown'}"
      ].join("\n")
    end
    private_class_method :root_body

    def render(title, body, presentation)
      case presentation
      when :plain then "*#{title}*\n#{body}"
      when :block then "*#{title}*\n```#{body}```"
      else raise ArgumentError, "unsupported message presentation: #{presentation.inspect}"
      end
    end
    private_class_method :render

    def validate_max_length(max_length, presentation)
      minimum_length = render('', '', presentation).length + 1
      return if max_length >= minimum_length

      raise ArgumentError, "max_length must be at least #{minimum_length} for #{presentation} messages"
    end
    private_class_method :validate_max_length

    def fit_title(title, presentation, max_length, empty_body, continuation:)
      body_reserve = empty_body ? 0 : 1
      max_title_length = max_length - render('', '', presentation).length - body_reserve
      return truncate(title, max_title_length) unless continuation
      return truncate(CONTINUATION_LABEL, max_title_length) if max_title_length <= CONTINUATION_LABEL.length

      base = truncate(title, max_title_length - CONTINUATION_LABEL.length - 1)
      base.empty? ? CONTINUATION_LABEL : "#{base} #{CONTINUATION_LABEL}"
    end
    private_class_method :fit_title

    def truncate(text, max_length)
      return '' if max_length <= 0
      return text if text.length <= max_length
      return '…' if max_length == 1

      "#{text[0, max_length - 1]}…"
    end
    private_class_method :truncate
  end
end
