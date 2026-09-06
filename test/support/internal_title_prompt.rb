# frozen_string_literal: true

module InternalTitlePromptSupport
  def internal_title_prompt
    <<~TEXT
      You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
      The task usually has to do with coding work, such as fixing a bug, changing a feature, or answering a question about a codebase.
      Generate a concise UI title of at most 36 characters.
      Use a single line of plain text only.
      Do not include quotes, markdown, formatting characters, or trailing punctuation.
      If the prompt includes a ticket reference, include it verbatim.
      Prefer an imperative verb when the user is asking for a change.
      Do not answer the user or attempt the task.

      User prompt:
      Fix the failing unit test
    TEXT
  end
end
