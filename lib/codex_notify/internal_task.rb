# frozen_string_literal: true

module CodexNotify
  module InternalTask
    module_function

    # Match the complete known envelope, not title-related words or JSON output.
    TITLE_INSTRUCTIONS = <<~TEXT.split.join(' ').freeze
      You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
      The task usually has to do with coding work, such as fixing a bug, changing a feature, or answering a question about a codebase.
      Generate a concise UI title of at most 36 characters.
      Use a single line of plain text only.
      Do not include quotes, markdown, formatting characters, or trailing punctuation.
      If the prompt includes a ticket reference, include it verbatim.
      Prefer an imperative verb when the user is asking for a change.
      Do not answer the user or attempt the task.
    TEXT

    def title_prompt?(prompt)
      instructions, separator, user_prompt = prompt.to_s.strip.partition(/\r?\n\s*User prompt:\s*\r?\n/)
      !separator.empty? && !user_prompt.strip.empty? && instructions.split.join(' ') == TITLE_INSTRUCTIONS
    end
  end
end
