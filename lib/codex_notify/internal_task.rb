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

    COMPOSER_PREDICTION_INSTRUCTIONS = <<~TEXT.split.join(' ').freeze
      This is an app-generated request for a suggested next user message. The user did not write this message.

      Your suggestion will appear in the user's empty message composer. They can accept it, edit it, or ignore it; it will not be sent automatically.

      Predict the single message this user is most likely to type next from the visible conversation. Use the whole conversation to understand their current intent and the latest exchange. Choose the action and specific object that best continue that intent, rather than a generally useful follow-up. Express its core naturally in the user's voice, keeping the requirements needed to retain its meaning. Choose the strongest grounded move even if several continuations are possible; uncertainty about exact wording or incidental details is not a reason to return null. Use null only when the conversation offers no grounded next move at all.

      Set suggestion to exactly one natural user message, one line, at most 240 characters, or null. No alternatives or explanation.

      Return only JSON matching this schema: {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"suggestion":{"type":["string","null"]}},"required":["suggestion"],"additionalProperties":false}.
    TEXT

    def suppression_reason(prompt)
      return 'internal_title_generation' if title_prompt?(prompt)
      return 'internal_composer_prediction' if composer_prediction_prompt?(prompt)

      nil
    end

    def composer_prediction_prompt?(prompt)
      prompt.to_s.split.join(' ') == COMPOSER_PREDICTION_INSTRUCTIONS
    end

    def title_prompt?(prompt)
      instructions, separator, user_prompt = prompt.to_s.strip.partition(/\r?\n\s*User prompt:\s*\r?\n/)
      !separator.empty? && !user_prompt.strip.empty? && instructions.split.join(' ') == TITLE_INSTRUCTIONS
    end
  end
end
