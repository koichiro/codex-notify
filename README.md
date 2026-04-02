# codex-notify

[![CI](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/coverage-80%25-brightgreen)](#development)
[![Ruby](https://img.shields.io/badge/ruby-3.2%2B-red)](#development)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](./LICENSE)

`codex-notify` is a small Ruby CLI tool that posts compact Slack notifications from Codex.

It supports two modes:

- log tail mode, which tails Codex session log files
- hook mode, which posts directly from Codex Hooks

It is intended for lightweight run visibility without a separate service.

## Purpose

- Send Codex activity to Slack without building a separate service
- Keep Slack notifications focused on prompts, responses, and optional tool activity
- Support both session-log tailing and Codex Hooks

## Modes

### Log Tail Mode

This is the original mode. It tails a Codex session log under `~/.codex/sessions` and posts updates as new items are appended.

### Hook Mode

This mode uses Codex Hooks instead of transcript tailing.

- One Slack thread per Codex `session_id`
- `SessionStart` creates the session thread root if needed
- `UserPromptSubmit` posts the user prompt into that thread
- `PreToolUse` and `PostToolUse` can post Bash tool activity
- `Stop` posts `last_assistant_message` for the completed turn

This keeps all prompts and replies for the same Codex session in one Slack thread and does not require tailing a session log.

## How It Works

### Log Tail Mode

1. The script loads configuration from `.env`, environment variables, and CLI flags.
2. It posts a small root Slack message showing that monitoring has started.
3. It finds a Codex session log file under `~/.codex/sessions` or uses the file you specify.
4. It tails that log from the end, so existing history is not reposted on startup.
5. Each newly detected user prompt is posted as a new Slack thread root.
6. Codex responses and optional tool events are posted into that prompt's thread.

### Hook Mode

1. Codex invokes `bin/codex-notify-hook` for configured hook events.
2. The hook command reads the JSON payload from standard input.
3. A per-session Slack thread is created and stored on first use.
4. Later hook events for the same `session_id` are posted into the same thread.

## Supported Behavior

- Log tail mode:
  - one monitoring-start message with run title and working directory
  - monitoring-start message also includes the configured user label and session ID
  - one new Slack thread for each new user prompt
  - thread replies for assistant responses and concise failure notices
  - optional thread replies for `command_execution`, `file_change`, `web_search`, and other completed items
- Hook mode:
  - one Slack thread per Codex session
  - prompt, Bash tool activity, and final assistant messages posted from hook events
  - local state file used to remember Slack thread timestamps across hook invocations
- Shared:
  - long payloads are split into safe chunks before posting
  - `.env` loading via `dotenv`

## Project Layout

```text
.
├── .codex/
│   └── hooks.json.example
├── .env.sample
├── .gitignore
├── README.md
├── bin/
│   ├── codex-notify-hook
│   └── codex-notify
├── Rakefile
├── lib/
│   └── codex_notify/
│       ├── cli.rb
│       ├── hook_cli.rb
│       ├── hook_config.rb
│       ├── hook_formatter.rb
│       ├── hook_runner.rb
│       ├── hook_store.rb
│       └── slack_client.rb
└── test/
    ├── test_cli.rb
    └── test_hook_cli.rb
```

## Configuration

Create `.env` from `.env.sample`.

```env
SLACK_BOT_TOKEN=xoxb-your-token
SLACK_CHANNEL=C0123456789
CODEX_NOTIFY_USER_NAME=user
CODEX_PROMPT=
CODEX_NOTIFY_TITLE=
```

Variables:

- `SLACK_BOT_TOKEN`: Slack bot token used for `chat.postMessage`
- `SLACK_CHANNEL`: Slack channel ID to receive the run thread
- `CODEX_NOTIFY_USER_NAME`: Label used for user messages in Slack, default is the local system user
- `CODEX_PROMPT`: Optional initial prompt to post as a user message when monitoring begins
- `CODEX_NOTIFY_TITLE`: Optional title used for the root Slack message or hook session thread

CLI flags override environment variables.

## Usage

Install dependencies first:

```bash
bundle install
```

### Log Tail Mode

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
./bin/codex-notify
```

The entrypoint loads `bundler/setup`, so `bundle exec` is not required after `bundle install`.

Monitor a specific session file:

```bash
./bin/codex-notify --session-file ~/.codex/sessions/2026/03/10/rollout-....jsonl
```

Process the current contents once and exit:

```bash
./bin/codex-notify --once
```

In normal follow mode, `codex-notify` starts from the end of the session log and only posts prompts and responses appended after the monitor starts.

With explicit flags:

```bash
./bin/codex-notify \
  --token "$SLACK_BOT_TOKEN" \
  --channel "$SLACK_CHANNEL" \
  --user-name "koichiro" \
  --title "Codex run: my-project" \
  --prompt "Investigate failing tests"
```

Including tool events:

```bash
./bin/codex-notify --include-tools
```

Using a custom env file:

```bash
./bin/codex-notify --env-file .env.local
```

Using a custom sessions directory:

```bash
./bin/codex-notify --sessions-dir ~/.codex/sessions
```

Without `--no-alt-screen`, Codex switches to its alternate screen UI and the execution logs used by this tool are not emitted in the expected form.

### Hook Mode

Codex Hooks can be used instead of session-log tailing.

1. Copy `.codex/hooks.json.example` to either `~/.codex/hooks.json` or `<repo>/.codex/hooks.json`.
2. Set `SLACK_BOT_TOKEN` and `SLACK_CHANNEL`.
3. Run Codex normally.

Example hook config:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "./bin/codex-notify-hook --event SessionStart"
      }
    ],
    "UserPromptSubmit": [
      {
        "type": "command",
        "command": "./bin/codex-notify-hook --event UserPromptSubmit"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "type": "command",
        "command": "./bin/codex-notify-hook --event PreToolUse"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "type": "command",
        "command": "./bin/codex-notify-hook --event PostToolUse"
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "./bin/codex-notify-hook --event Stop"
      }
    ]
  }
}
```

The hook command reads each event payload from standard input:

```bash
./bin/codex-notify-hook --event UserPromptSubmit
```

Useful options:

- `--title "Codex session: my-project"`: override the Slack thread title
- `--user-name "koichiro"`: override the user label
- `--state-file ~/.codex-notify-hook/state.json`: change where session thread mappings are stored
- `--env-file .env.local`: load a different env file

Hook mode does not require `--no-alt-screen`, because it does not depend on session-log tailing.

## Development

Run tests:

```bash
rake
```

`Rakefile` also loads `bundler/setup`, so `rake` can be run without `bundle exec` after `bundle install`.

The test suite uses `minitest`, runs through `rake`, and enforces 80% line coverage for files under `lib/`.
