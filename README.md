# codex-notify

`codex-notify` is a small CLI tool that reads Codex JSONL event streams from `stdin` and posts them into a Slack thread.

It is intended for lightweight run visibility: one root Slack message per run, then thread replies for turns, assistant messages, failures, and optionally tool events.

## Purpose

- Send Codex run progress to Slack without building a separate service
- Preserve the original event payloads instead of summarizing them
- Keep one run grouped in a single Slack thread

## How It Works

1. The script loads configuration from `.env`, environment variables, and CLI flags.
2. It posts a root Slack message containing the working directory and prompt.
3. It reads JSONL events from `stdin`.
4. It converts selected events into Slack thread replies.
5. It optionally includes noisy tool events such as command execution and file changes.

## Supported Behavior

- Root thread message with run title, current working directory, and prompt
- Thread replies for:
  - `turn.started`
  - `turn.failed`
  - `item.completed` assistant/user messages
- Optional thread replies for:
  - `command_execution`
  - `file_change`
  - `web_search`
  - other completed items
- Long payloads are split into safe chunks before posting
- `.env` loading without requiring `python-dotenv`

## Project Layout

```text
.
├── .env.sample
├── .gitignore
├── README.md
├── codex-notify.py
├── pyproject.toml
├── src/
│   └── codex_notify/
│       ├── __init__.py
│       └── cli.py
└── tests/
    └── test_cli.py
```

## Configuration

Create `.env` from `.env.sample`.

```env
SLACK_BOT_TOKEN=xoxb-your-token
SLACK_CHANNEL=C0123456789
CODEX_PROMPT=
```

Variables:

- `SLACK_BOT_TOKEN`: Slack bot token used for `chat.postMessage`
- `SLACK_CHANNEL`: Slack channel ID to receive the run thread
- `CODEX_PROMPT`: Optional fallback prompt shown in the root message

CLI flags override environment variables.

## Usage

Basic usage:

```bash
python codex-notify.py < events.jsonl
```

With explicit flags:

```bash
python codex-notify.py \
  --token "$SLACK_BOT_TOKEN" \
  --channel "$SLACK_CHANNEL" \
  --title "Codex run: my-project" \
  --prompt "Investigate failing tests" \
  < events.jsonl
```

Including tool events:

```bash
python codex-notify.py --include-tools < events.jsonl
```

Using a custom env file:

```bash
python codex-notify.py --env-file .env.local < events.jsonl
```

## Input Format

The tool expects newline-delimited JSON objects on `stdin`.

Typical events:

- `turn.started`
- `turn.failed`
- `item.completed`

For `item.completed`, the script inspects `item.type` or `item.item_type`.

## Development

Create a virtual environment and install test dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .[test]
```

Run tests:

```bash
pytest
```

Run tests with coverage:

```bash
pytest --cov=src/codex_notify --cov-report=term-missing
```

The test suite is designed to stay above 70% coverage.
