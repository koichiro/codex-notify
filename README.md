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

1. The script loads configuration from the XDG config file, legacy `.env` files, environment variables, and CLI flags.
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
  - long payloads are split with titles and formatting overhead included in the Slack-safe limit
  - continuation chunks have an explicit `(cont.)` title; block-formatted chunks have balanced code fences
  - outbound messages are persisted to a local outbox before the first Slack request
  - HTTP 429 responses honor `Retry-After`; transient failures resume on a later invocation
  - trusted XDG YAML configuration plus legacy `.env` loading via `dotenv`

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

Create the trusted user configuration under the XDG configuration directory. When
`XDG_CONFIG_HOME` is set, codex-notify uses
`$XDG_CONFIG_HOME/codex-notify/config.yml`; otherwise it uses
`~/.config/codex-notify/config.yml`.

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/codex-notify"
touch "${XDG_CONFIG_HOME:-$HOME/.config}/codex-notify/config.yml"
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/codex-notify/config.yml"
```

```yaml
default_destination:
  token: xoxb-your-token
  channel: C0123456789

destinations:
  PROJECT_A:
    token: xoxb-project-a-token
    channel: C1111111111
  PROJECT_B:
    channel: C2222222222 # reuse the default token
```

The YAML schema intentionally has no version field. It accepts only
`env_policy`, `default_destination`, and `destinations`. Destination names are
normalized to uppercase and must contain only `A-Z`, `0-9`, and `_`.

Environment variables remain supported:

- `SLACK_BOT_TOKEN`: Slack bot token used for `chat.postMessage`
- `SLACK_CHANNEL`: Slack channel ID to receive the run thread
- `SLACK_BOT_TOKEN__NAME`: legacy-compatible Slack bot token for named destination `NAME`
- `SLACK_CHANNEL__NAME`: legacy-compatible required channel for named destination `NAME`
- `CODEX_NOTIFY_DESTINATION`: named Hook destination selected by a repository or process environment
- `CODEX_NOTIFY_ENV_POLICY`: repository env policy; defaults to `restricted`, with `legacy` retained temporarily as a trusted compatibility switch
- `CODEX_NOTIFY_USER_NAME`: Label used for user messages in Slack, default is the local system user
- `CODEX_PROMPT`: Optional initial prompt to post as a user message when monitoring begins
- `CODEX_NOTIFY_TITLE`: Optional title used for the root Slack message or hook session thread
- `CODEX_NOTIFY_MODE`: Hook notification mode, `normal` (default) or `debug`
- `CODEX_NOTIFY_OUTBOX_DIR`: optional private directory for durable pending Slack deliveries

Passing the token with `--token` is deprecated because command-line arguments can be exposed in process listings and shell history. Prefer the permission-restricted XDG config file or `SLACK_BOT_TOKEN` in the process environment. On systems with Unix permissions, codex-notify warns when a loaded config or env file is readable by group or other users.

Configuration is resolved in this order: explicit CLI values, process environment,
an explicit `--config PATH`, an explicit `--env-file PATH`, the default XDG
config file, an automatically discovered repository `.env`, and finally the
legacy codex-notify project-root `.env`. Explicit YAML and the default XDG file
are layered, so missing values in the explicit file may fall back to the default
file. The project-root `.env` remains supported during migration, but emits a
value-free deprecation warning when it supplies trusted credentials, profiles,
or the environment policy.

The XDG config path is never discovered relative to the current repository.
An explicitly set `XDG_CONFIG_HOME` must be absolute. YAML is loaded without
aliases, arbitrary Ruby objects, or symbols.

### Migrating a legacy env file

Create the XDG YAML file explicitly from the codex-notify project-root `.env`:

```bash
bin/codex-notify --migrate-config
```

To select both paths explicitly:

```bash
bin/codex-notify --migrate-config \
  --env-file /path/to/legacy.env \
  --config /path/to/config.yml
```

The migration copies only `CODEX_NOTIFY_ENV_POLICY`, the default Slack token
and channel, and named destination tokens and channels. Routing and presentation
settings remain in the env file. Destination names are normalized and every
named destination must have its own channel.

The command creates the output with mode `0600` and refuses to overwrite an
existing file. It does not modify or delete the source env file and never prints
credential values. After reviewing the generated YAML and verifying routing in
a new Codex session, remove migrated secrets from the legacy file manually.

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
- `--config PATH`: layer an explicit trusted YAML file above the default XDG config
- `--migrate-config`: create trusted YAML from the project-root or explicitly selected env file
- `--env-file .env.local`: load a different env file
- `--destination PROJECT_A`: select a trusted named Slack destination
- `--outbox-dir PATH`: override the durable delivery spool; repository `.env` files cannot set this in Hook mode
- `--outbox-status`: list delivery IDs and sanitized queue state without printing message text
- `--drain-outbox`: retry eligible queued deliveries without reading a Hook payload
- `--retry-outbox ID`: move one failed or acknowledgement-ambiguous delivery back to pending

`--token` remains available for compatibility but is deprecated. Prefer the
default or explicit `0600` YAML config file.

### Hook data and destination

The configured `SLACK_BOT_TOKEN` determines the Slack workspace, and `SLACK_CHANNEL` determines the default destination channel. Hook definitions are the allowlist: configure only the event types you intend to send. `codex-notify-hook` accepts only the following supported events and rejects other event names.

#### Named destination profiles

Named profiles let a repository select a preconfigured destination without storing Slack credentials or raw channel IDs in that repository. Define profiles in the trusted XDG YAML file:

```yaml
default_destination:
  token: xoxb-default-token
  channel: C0000000000

destinations:
  PROJECT_A:
    token: xoxb-project-a-token
    channel: C1111111111
  PROJECT_B:
    channel: C2222222222
```

A repository may then select the profile in its `.env` without owning the credentials:

```env
CODEX_NOTIFY_DESTINATION=PROJECT_A
CODEX_NOTIFY_TITLE=Project A
```

Destination names are normalized to uppercase and must contain only `A-Z`, `0-9`, and `_`. A destination-specific token takes precedence over the default token, while a destination-specific channel is required. A named destination never falls back to the default channel; an unknown or incomplete profile exits with status `2` before reading the Hook payload, posting to Slack, or updating state.

Explicit `--token` and `--channel` values remain highest priority, although `--token` is deprecated. Profile definitions from an automatically discovered repository `.env` are always ignored; named profile credentials must come from trusted YAML, the process environment, an explicitly supplied `--env-file`, or the deprecated tool-root `.env`.

#### Repository env policy and migration

The default `restricted` policy treats an automatically discovered repository
`.env` as an untrusted routing and presentation source. It may provide only
`CODEX_NOTIFY_DESTINATION`, `CODEX_NOTIFY_TITLE`, `CODEX_NOTIFY_USER_NAME`, and
`CODEX_NOTIFY_MODE`. Raw Slack credentials, raw channels, profile definitions,
and `CODEX_NOTIFY_ENV_POLICY` are ignored. Diagnostics identify ignored Slack
key names and the source path without printing their values.

An explicitly supplied `--env-file PATH` remains an intentional trusted source
and may contain credentials. Process environment values, explicit CLI values,
and trusted YAML configuration also retain their documented precedence.

For temporary compatibility, trusted configuration may explicitly restore the
legacy repository credential behavior:

```yaml
env_policy: legacy
```

Legacy mode emits a prominent value-free warning on every invocation where a
repository token or raw channel is actually selected. A repository `.env`
cannot enable legacy mode itself. This escape hatch is temporary and is planned
for removal in a future major release.

Before migration:

```env
# Repository .env
SLACK_BOT_TOKEN=xoxb-work-token
SLACK_CHANNEL=C1111111111
```

After migration:

```yaml
# $XDG_CONFIG_HOME/codex-notify/config.yml
destinations:
  PROJECT_A:
    token: xoxb-work-token
    channel: C1111111111
```

```env
# Repository .env
CODEX_NOTIFY_DESTINATION=PROJECT_A
```

Migration checklist:

1. Run `--migrate-config`, or manually create a `0600` XDG `config.yml` and translate the trusted settings.
2. Review the generated default destination, named destinations, and policy.
3. Replace repository credentials with `CODEX_NOTIFY_DESTINATION=NAME`.
4. Verify routing in a new Codex session.
5. Remove trusted credentials and policy settings from the project-root `.env`.

Migration runs only when explicitly requested. codex-notify never deletes
credentials automatically.

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

### Durable Slack delivery

Both modes format, chunk, and redact each logical notification before atomically
placing it in a private local outbox. The Slack transport uses 5-second connect,
10-second write, and 20-second read timeouts. A normal invocation uses a
10-second retry/sleep budget while draining eligible work; an in-progress HTTP
attempt remains governed by its separate timeouts. HTTP `429` waits use Slack's
`Retry-After` value; other definite transient failures use bounded exponential
backoff. Hook invocations remain quiet and return `0` after a notification is
durably queued, even when delivery is deferred to a later invocation.

Confirmed root timestamps and chunk progress are persisted, so a later process
continues from the first unconfirmed chunk. If a connection fails after a
request may have reached Slack, the acknowledgement is ambiguous: codex-notify
does not retry it again in the same invocation, permits at most three automatic
attempts across invocations, and then moves it to `needs-review`. Exactly-once
delivery is not guaranteed; one duplicate remains possible for each ambiguous
attempt. Definite failures are retried until delivered or manually handled.

The outbox never stores Slack tokens, Authorization headers, raw Hook payloads,
or raw JSONL events. It stores the final best-effort-redacted notification text,
which may still be sensitive. Its directories and files are created with modes
`0700` and `0600`. The queue is bounded to 10,000 non-delivered jobs and 64 MiB;
when full, it rejects new work with exit code `1` instead of evicting an existing
notification.

Hook mode defaults to `<state-file>.outbox`; log-tail mode defaults to
`~/.codex-notify/outbox`. Inspect or recover a queue with the same credentials
and path used by the normal command:

```bash
./bin/codex-notify-hook --outbox-status
./bin/codex-notify-hook --drain-outbox
./bin/codex-notify-hook --retry-outbox DELIVERY_ID
```

Status output contains IDs, timestamps, statuses, and sanitized error codes,
but never notification text. A failed or `needs-review` job blocks newer work
for the same session until it is retried; other sessions may continue. Session
reset events advance a local generation and cancel older queued work so it
cannot attach to the new Slack thread.

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

- `0`: the event was handled, suppressed intentionally, delivered, or durably queued for retry
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
- When using the macOS ChatGPT/Codex app, use an absolute hook command path and keep credentials in the XDG config file. GUI apps may not inherit the same `PATH` or environment variables as an interactive shell, so the default `~/.config/codex-notify/config.yml` path is usually the most predictable choice. Also verify that the command can locate Ruby, Bundler, and the installed gems.

Hook mode does not require `--no-alt-screen`, because it does not depend on session-log tailing.

## Development

Run tests:

```bash
rake
```

`Rakefile` also loads `bundler/setup`, so `rake` can be run without `bundle exec` after `bundle install`.

The test suite uses `minitest`, runs through `rake`, and enforces 90% line coverage for files under `lib/`.

Ruby 3.4 or newer is supported. CI covers the minimum supported 3.4 series and the 4.0 series used by the project's `.ruby-version`.
