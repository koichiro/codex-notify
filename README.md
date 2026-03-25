# codex-notify

[![CI](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/coverage-80%25-brightgreen)](#development)
[![Ruby](https://img.shields.io/badge/ruby-3.2%2B-red)](#development)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](./LICENSE)

`codex-notify` is a small Ruby CLI tool that tails Codex session log files and posts compact Slack notifications.

It is intended for lightweight run visibility: one small monitoring-start message, then one Slack thread per new user prompt with the corresponding Codex responses attached.

## Purpose

- Send Codex conversations to Slack without building a separate service
- Keep Slack notifications focused on prompts and responses
- Start a fresh Slack thread for each new user prompt

## How It Works

1. The script loads configuration from `.env`, environment variables, and CLI flags.
2. It posts a small root Slack message showing that monitoring has started.
3. It finds a Codex session log file under `~/.codex/sessions` or uses the file you specify.
4. It tails that log from the end, so existing history is not reposted on startup.
5. Each newly detected user prompt is posted as a new Slack thread root.
6. Codex responses and optional tool events are posted into that prompt's thread.

## Supported Behavior

- One monitoring-start message with run title and working directory
- Monitoring-start message also includes the configured user label and session ID
- One new Slack thread for each new user prompt
- Thread replies for:
  - assistant responses
  - concise failure notices
- Optional thread replies for:
  - `command_execution`
  - `file_change`
  - `web_search`
  - other completed items
- Long payloads are split into safe chunks before posting
- `.env` loading via `dotenv`

## Project Layout

```text
.
├── .env.sample
├── .gitignore
├── README.md
├── codex-notify.rb
├── Rakefile
├── lib/
│   └── codex_notify/
│       └── cli.rb
└── test/
    └── test_cli.rb
```

## Configuration

Create `.env` from `.env.sample`.

```env
SLACK_BOT_TOKEN=xoxb-your-token
SLACK_CHANNEL=C0123456789
CODEX_NOTIFY_USER_NAME=user
CODEX_PROMPT=
```

Variables:

- `SLACK_BOT_TOKEN`: Slack bot token used for `chat.postMessage`
- `SLACK_CHANNEL`: Slack channel ID to receive the run thread
- `CODEX_NOTIFY_USER_NAME`: Label used for user messages in Slack, default is the local system user
- `CODEX_PROMPT`: Optional initial prompt to post as a user message when monitoring begins

CLI flags override environment variables.

## Usage

Install dependencies first:

```bash
bundle install
```

### Running With Codex

`codex-notify` reads Codex session logs directly, so piping Codex output into this tool is not required.

Codex should still be started with `--no-alt-screen`, because that is the supported way to keep its execution output compatible with this workflow.

Start a new Codex run:

```bash
codex --no-alt-screen
```

Resume the previous Codex session:

```bash
codex --no-alt-screen resume
```

Run `codex-notify` separately:

```bash
ruby codex-notify.rb
```

The entrypoint loads `bundler/setup`, so `bundle exec` is not required after `bundle install`.

Monitor a specific session file:

```bash
ruby codex-notify.rb --session-file ~/.codex/sessions/2026/03/10/rollout-....jsonl
```

Process the current contents once and exit:

```bash
ruby codex-notify.rb --once
```

In normal follow mode, `codex-notify` starts from the end of the session log and only posts prompts and responses appended after the monitor starts.

With explicit flags:

```bash
ruby codex-notify.rb \
  --token "$SLACK_BOT_TOKEN" \
  --channel "$SLACK_CHANNEL" \
  --user-name "koichiro" \
  --title "Codex run: my-project" \
  --prompt "Investigate failing tests"
```

Including tool events:

```bash
ruby codex-notify.rb --include-tools
```

Using a custom env file:

```bash
ruby codex-notify.rb --env-file .env.local
```

Using a custom sessions directory:

```bash
ruby codex-notify.rb --sessions-dir ~/.codex/sessions
```

Without `--no-alt-screen`, Codex switches to its alternate screen UI and the execution logs used by this tool are not emitted in the expected form.

## Development

Run tests:

```bash
rake
```

`Rakefile` also loads `bundler/setup`, so `rake` can be run without `bundle exec` after `bundle install`.

The test suite uses `minitest`, runs through `rake`, and enforces 80% line coverage for files under `lib/`.
