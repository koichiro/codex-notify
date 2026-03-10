#!/usr/bin/env python3

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Iterator, Optional, TextIO

SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_ENV_PATH = ".env"


def load_env_file(path: str = DEFAULT_ENV_PATH, override: bool = False) -> None:
    env_path = Path(path)
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if not override and os.environ.get(key):
            continue
        os.environ[key] = value


def slack_post(
    token: str,
    channel: str,
    text: str,
    thread_ts: Optional[str] = None,
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"channel": channel, "text": text}
    if thread_ts:
        payload["thread_ts"] = str(thread_ts)

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SLACK_API,
        data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    res = json.loads(body)
    if not res.get("ok"):
        raise RuntimeError(f"Slack API error: {res}")
    return res


def chunk_text(text: str, max_len: int = 3500) -> Iterator[str]:
    normalized = text.replace("\r\n", "\n")
    for index in range(0, len(normalized), max_len):
        yield normalized[index : index + max_len]


def fmt_block(title: str, body: str) -> str:
    return f"*{title}*\n```{body}```"


def getenv_any(keys: Iterable[str]) -> Optional[str]:
    for key in keys:
        value = os.environ.get(key)
        if value:
            return value
    return None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Post Codex JSONL events to Slack threads.")
    parser.add_argument(
        "--env-file",
        default=DEFAULT_ENV_PATH,
        help="dotenv file to load before reading CLI defaults",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Slack bot token (or env SLACK_BOT_TOKEN)",
    )
    parser.add_argument(
        "--channel",
        default=None,
        help="Slack channel ID (or env SLACK_CHANNEL)",
    )
    parser.add_argument(
        "--prompt",
        default=None,
        help="Root message prompt text (also shown as thread root)",
    )
    parser.add_argument("--title", default=None, help="Root message title prefix")
    parser.add_argument(
        "--include-tools",
        action="store_true",
        help="Also post command_execution/file_change/web_search items",
    )
    parser.add_argument(
        "--throttle-sec",
        type=float,
        default=1.05,
        help="Sleep between Slack posts",
    )
    return parser


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = build_parser()
    args = parser.parse_args(argv)
    load_env_file(args.env_file)

    if not args.token:
        args.token = os.environ.get("SLACK_BOT_TOKEN")
    if not args.channel:
        args.channel = os.environ.get("SLACK_CHANNEL")
    return args


def process_events(
    stream: TextIO,
    token: str,
    channel: str,
    root_text: str,
    include_tools: bool = False,
    throttle_sec: float = 0.0,
    post_func: Callable[[str, str, str, Optional[str]], Dict[str, Any]] = slack_post,
    sleep_func: Callable[[float], None] = time.sleep,
) -> int:
    root_res = post_func(token, channel, root_text, None)
    thread_ts = str(root_res["ts"])
    sleep_func(throttle_sec)

    turn_idx = 0

    def post_thread(title: str, body: str) -> None:
        for part in chunk_text(body):
            post_func(token, channel, fmt_block(title, part), thread_ts)
            sleep_func(throttle_sec)

    for raw in stream:
        line = raw.strip()
        if not line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        event_type = event.get("type")

        if event_type == "turn.started":
            turn_idx += 1
            post_thread(f"turn {turn_idx} started", json.dumps(event, ensure_ascii=False))
            continue

        if event_type == "turn.failed":
            post_thread(f"turn {turn_idx} FAILED", json.dumps(event, ensure_ascii=False))
            continue

        if event_type != "item.completed":
            continue

        item = event.get("item") or {}
        item_type = item.get("type") or item.get("item_type")

        if item_type in ("agent_message", "assistant_message", "assistant"):
            text = item.get("text") or item.get("content") or ""
            post_thread(
                f"assistant (turn {turn_idx})",
                text if text else json.dumps(item, ensure_ascii=False),
            )
            continue

        if item_type in ("user_message", "user"):
            text = item.get("text") or item.get("content") or ""
            post_thread(
                f"user (turn {turn_idx})",
                text if text else json.dumps(item, ensure_ascii=False),
            )
            continue

        if not include_tools:
            continue

        if item_type == "command_execution":
            command = item.get("command") or item.get("cmd") or ""
            exit_code = item.get("exit_code")
            stdout = item.get("stdout") or ""
            stderr = item.get("stderr") or ""
            body = (
                f"COMMAND:\n{command}\n\n"
                f"EXIT_CODE: {exit_code}\n\n"
                f"STDOUT:\n{stdout}\n\n"
                f"STDERR:\n{stderr}"
            )
            post_thread(f"command_execution (turn {turn_idx})", body)
            continue

        if item_type == "file_change":
            post_thread(f"file_change (turn {turn_idx})", json.dumps(item, ensure_ascii=False))
            continue

        if item_type == "web_search":
            post_thread(f"web_search (turn {turn_idx})", json.dumps(item, ensure_ascii=False))
            continue

        post_thread(
            f"item.completed ({item_type}) (turn {turn_idx})",
            json.dumps(item, ensure_ascii=False),
        )

    post_thread("Codex run finished", "EOF")
    return 0


def main(argv: Optional[list[str]] = None, stdin: Optional[TextIO] = None) -> int:
    args = parse_args(argv)
    if not args.token or not args.channel:
        print(
            "ERROR: need --token/--channel or env SLACK_BOT_TOKEN / SLACK_CHANNEL",
            file=sys.stderr,
        )
        return 2

    prompt = args.prompt or getenv_any(["CODEX_PROMPT", "PROMPT"])
    cwd = os.getcwd()
    title = args.title or f"Codex run: {os.path.basename(cwd)}"
    root_text = fmt_block(
        title,
        f"CWD: {cwd}\n\nPROMPT:\n{prompt or '(prompt not provided)'}",
    )

    return process_events(
        stdin or sys.stdin,
        token=args.token,
        channel=args.channel,
        root_text=root_text,
        include_tools=args.include_tools,
        throttle_sec=args.throttle_sec,
    )


if __name__ == "__main__":
    raise SystemExit(main())
