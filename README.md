# codex-notify

[![CI](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/koichiro/codex-notify/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/coverage-90%25-brightgreen)](#development)
[![Ruby](https://img.shields.io/badge/ruby-3.4%2B-red)](#development)
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
- The first `UserPromptSubmit` becomes the Slack thread root
- Later `UserPromptSubmit` events in the same session are posted as replies in that thread
- `SessionStart` does not post in normal mode and creates a diagnostic session root in debug mode
- `SessionStart.source = startup` and `SessionStart.source = clear` reset the saved Slack thread for that session
- `SessionStart.source = resume` keeps using the existing Slack thread
- `PermissionRequest` posts when Codex is waiting for approval
- `PreToolUse` and `PostToolUse` post Bash tool activity only in debug mode
- `Stop` posts `last_assistant_message` for the completed turn

This keeps all prompts and replies for the same Codex session in one Slack thread and does not require tailing a session log. Normal mode also avoids a separate "hook started" root message.

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
2. The hook command reads up to 1 MiB of JSON payload from standard input.
3. The first `UserPromptSubmit` creates the per-session Slack thread and stores its thread timestamp.
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
  - the first user prompt becomes the thread root
  - long root events use their first chunk as the root and post the remaining chunks as replies
  - user prompts, approval requests, and final assistant messages posted from hook events
  - session starts and Bash tool activity posted only in debug mode
  - local state file used to remember Slack thread timestamps across hook invocations
  - a user prompt containing only `---` resets the current session thread without posting to Slack
  - if a saved Slack thread timestamp becomes stale, the hook clears it, recreates the session thread, and retries the current event once
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
│       ├── config_support.rb
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

Create `.env` from `.env.sample`, then restrict it to the current user because it contains the Slack bot token.

```bash
cp .env.sample .env
chmod 600 .env
```

```env
SLACK_BOT_TOKEN=xoxb-your-token
SLACK_CHANNEL=C0123456789
CODEX_NOTIFY_USER_NAME=user
CODEX_PROMPT=
CODEX_NOTIFY_TITLE=
CODEX_NOTIFY_MODE=normal
```

Variables:

- `SLACK_BOT_TOKEN`: Slack bot token used for `chat.postMessage`
- `SLACK_CHANNEL`: Slack channel ID to receive the run thread
- `CODEX_NOTIFY_USER_NAME`: Label used for user messages in Slack, default is the local system user
- `CODEX_PROMPT`: Optional initial prompt to post as a user message when monitoring begins
- `CODEX_NOTIFY_TITLE`: Optional title used for the root Slack message or hook session thread
- `CODEX_NOTIFY_MODE`: Hook notification mode, `normal` (default) or `debug`

CLI flags override environment variables. Passing the token with `--token` is deprecated because command-line arguments can be exposed in process listings and shell history. Use `SLACK_BOT_TOKEN` from the environment or a permission-restricted env file instead. On systems with Unix permissions, codex-notify warns when a loaded env file is readable by group or other users.

When `--env-file` is omitted, `codex-notify` first looks for `.env` in the current working directory and then falls back to the tool's own project root. This helps hook mode when the executable is launched from another repository.

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
If `rbenv` is available, the entrypoint re-execs itself with the Ruby version from this project's `.ruby-version`, even when launched from another repository.

Monitor a specific session file:

```bash
./bin/codex-notify --session-file ~/.codex/sessions/2026/03/10/rollout-....jsonl
```

Process the current contents once and exit:

```bash
./bin/codex-notify --once
```

In normal follow mode, `codex-notify` starts from the end of the session log and only posts prompts and responses appended after the monitor starts.

With explicit non-secret flags:

```bash
./bin/codex-notify \
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

1. Enable hooks in `~/.codex/config.toml`.
2. Place `codex-notify-hook` at a stable absolute path.
3. Create `~/.codex/hooks.json` or `<repo>/.codex/hooks.json`.
4. Set `SLACK_BOT_TOKEN` and `SLACK_CHANNEL`.
5. Restart Codex, review and trust the hook definition, and run it normally.

Example `~/.codex/config.toml` addition:

```toml
[features]
hooks = true
```

Hooks are enabled by default in current Codex releases, so this setting is only needed if hooks were previously disabled. `codex_hooks` is a deprecated compatibility alias; use `hooks` for new configuration.

Recommended install location:

```bash
mkdir -p /home/codex-notify/bin
cp /path/to/codex-notify/bin/codex-notify-hook /home/codex-notify/bin/codex-notify-hook
chmod +x /home/codex-notify/bin/codex-notify-hook
```

Use an absolute path for hook commands. Codex runs hooks from the current project working directory, so relative paths are fragile when you want to share one hook command across multiple repositories.

Example hook config:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event PostToolUse"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event PermissionRequest"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/codex-notify/bin/codex-notify-hook --event Stop"
          }
        ]
      }
    ]
  }
}
```

The hook command reads each event payload from standard input:

```bash
/home/codex-notify/bin/codex-notify-hook --event UserPromptSubmit
```

Useful options:

- `--title "Codex session: my-project"`: override the Slack thread title
- `--user-name "koichiro"`: override the user label
- `--state-file ~/.codex-notify-hook/state.json`: change where session thread mappings are stored
- `--mode normal|debug`: choose normal notifications or detailed debug notifications
- `--env-file .env.local`: load a different env file

`--token` remains available for compatibility but is deprecated. Prefer `SLACK_BOT_TOKEN` in a `0600` env file.

### Hook data and destination

The configured `SLACK_BOT_TOKEN` determines the Slack workspace, and `SLACK_CHANNEL` determines the destination channel. Hook definitions are the allowlist: configure only the event types you intend to send. `codex-notify-hook` accepts only the following supported events and rejects other event names.

| Hook event | Mode | Data sent to Slack |
| --- | --- | --- |
| `SessionStart` | debug only | working directory, user label, and session ID |
| `UserPromptSubmit` | normal and debug | user prompt |
| `PreToolUse` | debug only | Bash command/tool input |
| `PostToolUse` | debug only | exit code, command output, and stderr |
| `PermissionRequest` | normal and debug | tool name and approval description |
| `Stop` | normal and debug | final assistant message |

> **Security warning:** debug mode sends commands and their output to Slack. These values can contain credentials, environment variables, file contents, or other sensitive data. Enable debug mode only for channels and sessions where that disclosure is acceptable. Omit `PreToolUse` and `PostToolUse` from the Hook configuration when tool activity should never be sent.

Before each Slack API request, codex-notify applies best-effort redaction to both log-tail and Hook messages. It masks common secret-bearing keys (such as token, password, secret, API key, and Authorization), explicit secret CLI flags, and several well-known token formats. Redaction cannot recognize every arbitrary or encoded secret, so it is an additional safeguard rather than a substitute for limiting Hook types, avoiding sensitive debug sessions, and restricting the Slack destination.

### Hook input contract

Hook input must be a non-empty JSON object. The event name may be supplied with
`--event` or by the payload's `hook_event_name` / `event` field. If more than one
source supplies an event name, the normalized names must agree. Supported event
names are `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PermissionRequest`, and `Stop`; the existing case-insensitive aliases with
spaces, `_`, or `-` are also accepted.

Hook input is limited to 1 MiB (1,048,576 bytes). Larger input is rejected before
JSON parsing, Slack posting, or state updates, with exit code `2`. The limit is
measured in bytes, including JSON syntax and multibyte string content.

Every event must include a non-empty string session ID as `session_id`,
`sessionId`, or `session.id`. Events without a valid session ID are rejected and
are never assigned to a shared default Slack thread.

Required event fields:

| Event | Required payload fields |
| --- | --- |
| `SessionStart` | non-empty string `source` |
| `UserPromptSubmit` | non-empty string `prompt` |
| `PreToolUse` | non-empty string `tool_name` and `tool_input` (legacy `command` is accepted) |
| `PostToolUse` | non-empty string `tool_name` and `tool_response` (legacy result fields are accepted) |
| `PermissionRequest` | non-empty string `tool_name` and object `tool_input` |
| `Stop` | string `last_assistant_message`; an empty string is a valid no-op |

The existing supported nested `payload` paths for prompts, permission requests,
tool results, and assistant messages remain accepted. Additional fields are
ignored for forward compatibility.

Hook command exit codes are:

- `0`: the event was handled, including intentional notification suppression
- `1`: a runtime failure occurred, such as a Slack or state-file error
- `2`: configuration or Hook input was invalid

Input errors write a concise `ERROR:` line to stderr without including the full
payload or credentials.

Notes:

- Hook config uses matcher groups. Each event contains an array of groups, and each group contains a `hooks` array of handlers.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, and `Stop` are the event names.
- Normal mode posts user prompts, approval requests, and final assistant messages. Debug mode additionally posts session starts and tool activity.
- Current Codex releases require non-managed command hooks to be reviewed and trusted. In Codex CLI, use `/hooks` to inspect and trust a new or changed hook definition. Until it is trusted, Codex skips it.
- Current hook payloads provide Bash commands under `tool_input.command` and completed tool results under `tool_response`. Legacy payload shapes remain supported by `codex-notify-hook`.
- In hook mode, a prompt containing only `---` clears the saved Slack thread for that Codex session. The next user prompt starts a new Slack thread.
- If Slack rejects a saved `thread_ts` with a thread-not-found style error, hook mode now clears that saved value automatically and recreates the thread on the current event.
- This executable pins `BUNDLE_GEMFILE` to its own project, so it can be launched from other repositories without resolving the wrong `Gemfile`.
- If `rbenv` is installed, the executable also re-execs with the Ruby version declared in this project's `.ruby-version`, so another repository's `.ruby-version` does not take precedence.
- The hook implementation keeps normal successful runs quiet so Codex does not show extra debug-style output from the hook itself.
- When using the macOS ChatGPT/Codex app, use an absolute hook command path and keep credentials in the tool's `.env` file. GUI apps may not inherit the same `PATH` or environment variables as an interactive shell, so verify that the command can locate Ruby, Bundler, and the installed gems.

Hook mode does not require `--no-alt-screen`, because it does not depend on session-log tailing.

## Development

Run tests:

```bash
rake
```

`Rakefile` also loads `bundler/setup`, so `rake` can be run without `bundle exec` after `bundle install`.

The test suite uses `minitest`, runs through `rake`, and enforces 90% line coverage for files under `lib/`.

Ruby 3.4 or newer is supported. CI covers the minimum supported 3.4 series and the 4.0 series used by the project's `.ruby-version`.
