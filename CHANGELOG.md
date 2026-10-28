# Changelog

All notable changes to codex-notify are documented in this file. Releases from
1.0.0 onward follow [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-28

### Fixed

- Suppress known internal Codex task-title and Composer Predictions requests
  and their responses in Hook normal mode and log-tail mode, reducing internal
  activity sent to Slack while preserving ordinary prompts and quoted text.
- Preserve existing Hook conversation threads when suppressing these internal
  requests, and resume notifications on the next ordinary user prompt.
- Carry initial internal-prompt suppression to the first identified log
  session, including when the request is not repeated in the log.

### Development and security

- Add dependency audits before CI tests and package verification, daily and
  manually triggered audits, and GitHub Dependency Review on pull requests.
- Audit locked gems and the recorded Bundler version, require fresh advisory
  data, and prevent project advisory ignores from hiding known vulnerabilities.
- Update the preferred development Ruby and CI/release jobs to Ruby 4.0.7.
  Ruby 3.4 or newer remains supported; no configuration migration is required.

## [1.0.0] - 2026-08-13

### Added

- Added the `codex-notify` log-tail command, which follows Codex JSONL session
  logs without reposting existing history.
- Added the `codex-notify-hook` command for Codex Hooks, with one Slack thread
  per Codex session and support for prompts, permission requests, final
  responses, session lifecycle events, and optional Bash activity.
- Added normal and debug notification modes, Slack-safe message chunking,
  stale-thread recovery, and durable local delivery queues.
- Added trusted XDG YAML configuration, named Slack destinations, explicit
  configuration migration, and diagnostics that do not print secret values.

### Security

- Repository `.env` files use the restricted policy by default. They may select
  a trusted destination and presentation settings, but cannot provide Slack
  credentials, raw channel IDs, named profile credentials, or the policy
  override.
- The temporary trusted `legacy` policy remains available for migration and
  emits a warning whenever repository credentials are used. It is planned for
  removal in a future major release.
- Hook input is limited to 1 MiB, validated before state or network access, and
  rejects unsupported events or missing session identifiers with exit code 2.
- Outbound Slack messages receive best-effort secret redaction immediately
  before delivery. Local configuration, state, and outbox files use restrictive
  permissions where supported.
- RubyGems publication uses GitHub Actions OIDC Trusted Publishing and does not
  require a long-lived RubyGems API key.

### Compatibility and migration

- Ruby 3.4 or newer is required.
- Existing supported Hook event aliases and legacy payload shapes remain
  compatible.
- Move Slack credentials from repository or checkout `.env` files to
  `$XDG_CONFIG_HOME/codex-notify/config.yml` (or
  `~/.config/codex-notify/config.yml`) and let repositories select an existing
  destination with `CODEX_NOTIFY_DESTINATION`.
- Replace checkout-based Hook command paths with the absolute path returned by
  `command -v codex-notify-hook`, then review and trust the changed Hook
  definition in Codex.

[1.0.1]: https://github.com/koichiro/codex-notify/releases/tag/v1.0.1
[1.0.0]: https://github.com/koichiro/codex-notify/releases/tag/v1.0.0
