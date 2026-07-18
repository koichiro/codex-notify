# AGENTS.md

This file gives repository-specific guidance to coding agents working on
`codex-notify`. Keep changes small, testable, and consistent with the behavior
documented in `README.md`.

## Project overview

`codex-notify` is a Ruby CLI that sends compact Codex activity notifications to
Slack. It has two entry points:

- `bin/codex-notify` tails Codex JSONL session logs.
- `bin/codex-notify-hook` receives Codex Hook JSON on standard input.

Both modes share configuration, formatting, Slack delivery, and secret
redaction code under `lib/codex_notify/`. Preserve both modes when changing
shared code.

## Development environment

- Use Ruby 3.4 or newer. CI tests Ruby 3.4 and 4.0; `.ruby-version` selects the
  project's preferred local version.
- Install dependencies with `bundle install`.
- Run the complete test suite with `rake` (or `bundle exec rake`).
- The Minitest suite enforces at least 80% line coverage for `lib/`.
- Treat warnings as useful defects: the Rake test task enables Ruby warnings.

Do not commit `.env`, `.session`, `.bundle/`, or `vendor/`. Never print or place
real Slack tokens, channel data, session logs, or Hook payloads in tests,
fixtures, commits, or PR descriptions.

## Code organization

- Keep CLI option parsing and process exit behavior in `cli.rb` or
  `hook_cli.rb`.
- Keep environment and option resolution in the configuration classes and
  `config_support.rb`.
- Keep Hook payload validation in `hook_input_validator.rb`, event orchestration
  in `hook_runner.rb`, state persistence in `hook_store.rb`, and presentation in
  `hook_formatter.rb`.
- Keep log-tail parsing and orchestration in `session_log.rb`,
  `log_event_parser.rb`, and `stream_processor.rb`.
- Keep Slack HTTP behavior in `slack_client.rb` and shared outbound-message
  sanitization in `security.rb` and `message_formatter.rb`.
- Use `CodexNotify` as the namespace and follow the existing Ruby style,
  including `# frozen_string_literal: true`, keyword arguments, and small
  single-purpose methods.

Prefer extending an existing component over duplicating behavior between the
two modes. Avoid adding dependencies when the Ruby standard library or an
existing project helper is sufficient.

## Behavioral contracts

Changes must preserve the user-facing contracts in `README.md`, especially:

- Log-tail mode starts at the end in follow mode and does not repost old
  history.
- Hook mode maintains one Slack thread per Codex session and applies the
  documented reset and resume rules.
- Normal mode posts only prompts, permission requests, and final responses;
  debug mode may additionally post session starts and Bash tool activity.
- Hook input is bounded to 1 MiB, requires a valid session ID, accepts only the
  supported events, and returns exit code `2` for configuration or input errors.
- Supported legacy payload shapes and event aliases remain compatible unless a
  deliberate breaking change is documented.
- Long messages are chunked within Slack-safe limits, in order, without
  duplicating content during stale-thread recovery.
- Successful Hook invocations remain quiet.

If a change intentionally alters any of these contracts, update `README.md` in
the same PR.

## Security and reliability

- Redact outbound content immediately before every Slack API request. Treat
  redaction as defense in depth, not permission to collect additional data.
- Do not expose secrets in exception messages, stderr output, debug output, or
  test failure messages.
- Keep token configuration environment-based; do not encourage command-line
  token arguments.
- Preserve secure env-file permission checks and atomic, concurrency-safe Hook
  state updates.
- Keep network timeouts bounded and surface Slack API failures without including
  credentials or complete sensitive payloads.
- Do not broaden the Hook event allowlist or debug-mode disclosure without tests
  and matching security documentation.

## Testing expectations

- Add or update focused `test/test_*.rb` coverage for every behavior change and
  regression fix.
- Use Minitest assertions and the helpers in `test/test_helper.rb`.
- Stub Slack/network interactions; the test suite must not require credentials,
  a Slack workspace, Codex session history, or internet access.
- Use temporary directories for state files and session logs. Do not write test
  state into the repository or the user's Codex directory.
- Cover success, invalid input, failure, and boundary cases when changing input
  validation, chunking, persistence, recovery, or security behavior.
- Run the full `rake` suite before committing. For changes to entry points, also
  exercise the relevant `--help` or invalid-input path without real Slack
  credentials.

## Documentation and review

Keep `README.md`, `.env.sample`, and `.codex/hooks.json.example` synchronized
with configuration, CLI, or Hook contract changes. In the PR summary, call out
security implications, compatibility decisions, and the exact validation run.
