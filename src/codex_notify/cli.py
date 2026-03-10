#!/usr/bin/env python3

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Iterator, List, Optional, TextIO, Tuple

SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_ENV_PATH = ".env"
DEFAULT_SESSIONS_DIR = Path.home() / ".codex" / "sessions"


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


def build_root_text(title: str, cwd: str) -> str:
    return fmt_block(title, f"Codex log monitoring started.\nCWD: {cwd}")


def fmt_plain(title: str, body: str) -> str:
    return f"*{title}*\n{body}"


def getenv_any(keys: Iterable[str]) -> Optional[str]:
    for key in keys:
        value = os.environ.get(key)
        if value:
            return value
    return None


def _as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def _pretty_json(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False)
    except Exception:
        return _as_text(value)


def _format_tool_payload(payload: Dict[str, Any]) -> str:
    command = payload.get("command") or payload.get("cmd") or payload.get("argv")
    stdout = payload.get("stdout")
    stderr = payload.get("stderr")
    exit_code = payload.get("exit_code")

    if command is None and isinstance(payload.get("info"), dict):
        info = payload["info"]
        command = info.get("command") or info.get("cmd") or info.get("argv")
        stdout = stdout or info.get("stdout")
        stderr = stderr or info.get("stderr")
        if exit_code is None:
            exit_code = info.get("exit_code")

    if command is not None or stdout is not None or stderr is not None or exit_code is not None:
        if isinstance(command, list):
            command_text = " ".join(map(str, command))
        else:
            command_text = str(command) if command is not None else ""
        parts: List[str] = []
        if command_text:
            parts.append(f"$ {command_text}")
        if exit_code is not None:
            parts.append(f"[exit_code] {exit_code}")
        if stdout:
            parts.append("\n[stdout]\n" + str(stdout))
        if stderr:
            parts.append("\n[stderr]\n" + str(stderr))
        rendered = "\n".join(parts).strip()
        return rendered or _pretty_json(payload)

    for key in ("tool_name", "name", "tool", "function_name"):
        if payload.get(key):
            tool_name = payload.get(key)
            args = payload.get("arguments") or payload.get("args") or payload.get("input")
            result = payload.get("result") or payload.get("output")
            parts = [f"[tool] {tool_name}"]
            if args is not None:
                parts.append("[args]\n" + _pretty_json(args))
            if result is not None:
                parts.append("[result]\n" + _pretty_json(result))
            return "\n".join(parts)

    return _pretty_json(payload)


def _is_tool_event_type(event_type: Optional[str]) -> bool:
    if not event_type:
        return False
    return str(event_type) in {
        "command_execution",
        "shell_command",
        "tool_call",
        "tool_result",
        "tool",
        "mcp_tool_call",
        "mcp_tool_result",
        "mcp_call",
        "mcp_result",
        "sandbox_command",
    }


def extract_events(obj: Any) -> List[Tuple[str, str, str]]:
    events: List[Tuple[str, str, str]] = []

    if isinstance(obj, list):
        for item in obj:
            events.extend(extract_events(item))
        return events

    if not isinstance(obj, dict):
        return events

    object_type = obj.get("type")
    if object_type in ("input_text", "output_text"):
        text = _as_text(obj.get("text") or obj.get("content"))
        if text:
            kind = "user" if object_type == "input_text" else "assistant"
            events.append((kind, text, object_type))
        return events

    payload = obj.get("payload")
    if isinstance(payload, dict):
        payload_type = payload.get("type")

        if _is_tool_event_type(payload_type):
            events.append(("tool", _format_tool_payload(payload), "tool"))
            return events

        if payload_type in ("input_text", "output_text"):
            text = _as_text(payload.get("text") or payload.get("content"))
            if text:
                kind = "user" if payload_type == "input_text" else "assistant"
                events.append((kind, text, payload_type))
            return events

        if payload_type == "message":
            role = payload.get("role")
            content = payload.get("content")
            if content is None:
                content = payload.get("parts")

            if isinstance(content, list):
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    part_type = part.get("type")
                    if part_type in ("input_text", "output_text"):
                        text = _as_text(part.get("text") or part.get("content"))
                        if text:
                            kind = "user" if part_type == "input_text" else "assistant"
                            events.append((kind, text, part_type))
                    elif _is_tool_event_type(part_type):
                        events.append(("tool", _format_tool_payload(part), "tool"))
            else:
                text = _as_text(payload.get("text"))
                if text and role in ("user", "assistant"):
                    inferred = "input_text" if role == "user" else "output_text"
                    events.append((role, text, inferred))
            return events

        if payload_type == "user_message":
            text = _as_text(payload.get("message") or payload.get("text"))
            if text:
                events.append(("user", text, "input_text"))
            return events

        if payload_type == "agent_message":
            text = _as_text(payload.get("message") or payload.get("text"))
            if text:
                events.append(("assistant", text, "output_text"))
            return events

        if payload_type == "task_complete":
            text = _as_text(payload.get("last_agent_message"))
            if text:
                events.append(("assistant", text, "output_text"))
            return events

        nested_message = payload.get("message")
        if isinstance(nested_message, (dict, list)):
            events.extend(extract_events(nested_message))
            return events

        for key in ("tool", "tool_call", "tool_result", "command_execution", "command"):
            nested = payload.get(key)
            if isinstance(nested, dict):
                nested_type = nested.get("type") or key
                if _is_tool_event_type(nested_type) or key in ("command_execution", "command"):
                    events.append(("tool", _format_tool_payload(nested), "tool"))

    for key in ("message", "item", "response_item", "response_message", "data"):
        nested = obj.get(key)
        if isinstance(nested, (dict, list)):
            events.extend(extract_events(nested))

    return events


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
    parser.add_argument(
        "--sessions-dir",
        default=str(DEFAULT_SESSIONS_DIR),
        help="Codex sessions directory",
    )
    parser.add_argument(
        "--session-file",
        default=None,
        help="Specific Codex session jsonl file to monitor",
    )
    parser.add_argument(
        "--poll-sec",
        type=float,
        default=1.0,
        help="Polling interval when following a session file",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Process the current contents once instead of following for new lines",
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
    initial_prompt: Optional[str] = None,
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

    if initial_prompt:
        post_thread("user", initial_prompt)

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
            continue

        if event_type == "turn.failed":
            post_thread("system", f"turn {turn_idx} failed")
            continue

        if event_type != "item.completed":
            continue

        item = event.get("item") or {}
        item_type = item.get("type") or item.get("item_type")

        if item_type in ("agent_message", "assistant_message", "assistant"):
            text = item.get("text") or item.get("content") or ""
            post_thread(
                "assistant",
                text if text else json.dumps(item, ensure_ascii=False),
            )
            continue

        if item_type in ("user_message", "user"):
            text = item.get("text") or item.get("content") or ""
            post_thread(
                "user",
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


def iter_follow_lines(
    path: Path,
    poll_sec: float = 1.0,
    once: bool = False,
    start_at_end: bool = True,
    sleep_func: Callable[[float], None] = time.sleep,
) -> Iterator[str]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        if start_at_end:
            handle.seek(0, os.SEEK_END)
        while True:
            line = handle.readline()
            if line:
                yield line
                continue
            if once:
                break
            sleep_func(poll_sec)


def find_latest_session_file(sessions_dir: Path) -> Optional[Path]:
    if not sessions_dir.exists():
        return None
    files = [path for path in sessions_dir.rglob("*.jsonl") if path.is_file()]
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def process_codex_log_stream(
    stream: Iterable[str],
    token: str,
    channel: str,
    root_text: str,
    include_tools: bool = False,
    throttle_sec: float = 0.0,
    post_func: Callable[[str, str, str, Optional[str]], Dict[str, Any]] = slack_post,
    sleep_func: Callable[[float], None] = time.sleep,
) -> int:
    post_func(token, channel, root_text, None)
    sleep_func(throttle_sec)
    last_sent_fingerprint: Optional[str] = None
    current_thread_ts: Optional[str] = None

    def post_thread(title: str, body: str, thread_ts: Optional[str]) -> None:
        for part in chunk_text(body):
            formatter = fmt_plain if title in ("user", "assistant", "system") else fmt_block
            post_func(token, channel, formatter(title, part), thread_ts)
            sleep_func(throttle_sec)

    for raw in stream:
        line = raw.strip()
        if not line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        extracted_events = extract_events(event)
        if not extracted_events:
            continue

        for kind, text, part_type in extracted_events:
            if not text:
                continue
            if part_type == "tool" and not include_tools:
                continue

            fingerprint = f"{part_type}:{kind}:{text[:240]}"
            if fingerprint == last_sent_fingerprint:
                continue
            last_sent_fingerprint = fingerprint

            title = "assistant" if kind == "assistant" else kind
            if kind == "user":
                parts = list(chunk_text(text))
                if not parts:
                    continue
                current_thread_ts = str(
                    post_func(token, channel, fmt_plain("user", parts[0]), None)["ts"]
                )
                sleep_func(throttle_sec)
                for part in parts[1:]:
                    post_func(token, channel, fmt_plain("user(cont.)", part), current_thread_ts)
                    sleep_func(throttle_sec)
                continue

            post_thread(title, text, current_thread_ts)

    return 0


def main(argv: Optional[list[str]] = None, stdin: Optional[TextIO] = None) -> int:
    args = parse_args(argv)
    if not args.token or not args.channel:
        print(
            "ERROR: need --token/--channel or env SLACK_BOT_TOKEN / SLACK_CHANNEL",
            file=sys.stderr,
        )
        return 2

    cwd = os.getcwd()
    title = args.title or f"Codex run: {os.path.basename(cwd)}"
    root_text = build_root_text(title, cwd)
    session_file = Path(args.session_file) if args.session_file else find_latest_session_file(Path(args.sessions_dir))
    if not session_file or not session_file.exists():
        print("ERROR: no Codex session log file found", file=sys.stderr)
        return 2

    try:
        return process_codex_log_stream(
            iter_follow_lines(
                session_file,
                poll_sec=args.poll_sec,
                once=args.once,
                start_at_end=True,
                sleep_func=time.sleep,
            ),
            token=args.token,
            channel=args.channel,
            root_text=root_text,
            include_tools=args.include_tools,
            throttle_sec=args.throttle_sec,
        )
    except KeyboardInterrupt:
        print("Stopped.", file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
