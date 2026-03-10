# codex-notify

`codex-notify` is a small CLI tool that tails Codex session log files and posts compact Slack notifications.

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
- `CODEX_PROMPT`: Optional initial prompt to post as a user message when monitoring begins

CLI flags override environment variables.

## Usage

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
python codex-notify.py
```

Monitor a specific session file:

```bash
python codex-notify.py --session-file ~/.codex/sessions/2026/03/10/rollout-....jsonl
```

Process the current contents once and exit:

```bash
python codex-notify.py --once
```

In normal follow mode, `codex-notify` starts from the end of the session log and only posts prompts and responses appended after the monitor starts.

With explicit flags:

```bash
python codex-notify.py \
  --token "$SLACK_BOT_TOKEN" \
  --channel "$SLACK_CHANNEL" \
  --title "Codex run: my-project" \
  --prompt "Investigate failing tests"
```

Including tool events:

```bash
python codex-notify.py --include-tools
```

Using a custom env file:

```bash
python codex-notify.py --env-file .env.local
```

Using a custom sessions directory:

```bash
python codex-notify.py --sessions-dir ~/.codex/sessions
```

Without `--no-alt-screen`, Codex switches to its alternate screen UI and the execution logs used by this tool are not emitted in the expected form.

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
