import io
import os

import pytest

from codex_notify.cli import (
    _format_tool_payload,
    _is_tool_event_type,
    _pretty_json,
    _as_text,
    build_root_text,
    chunk_text,
    extract_events,
    fmt_block,
    find_latest_session_file,
    getenv_any,
    iter_follow_lines,
    load_env_file,
    main,
    parse_args,
    process_codex_log_stream,
    process_events,
)


def test_chunk_text_splits_long_text():
    text = "a" * 10
    parts = list(chunk_text(text, max_len=4))
    assert parts == ["aaaa", "aaaa", "aa"]


def test_fmt_block_wraps_title_and_body():
    assert fmt_block("title", "body") == "*title*\n```body```"


def test_build_root_text_is_minimal():
    text = build_root_text("title", "/tmp/project")
    assert "Codex log monitoring started." in text
    assert "CWD: /tmp/project" in text
    assert "PROMPT" not in text


def test_getenv_any_returns_first_match(monkeypatch):
    monkeypatch.delenv("FIRST", raising=False)
    monkeypatch.setenv("SECOND", "value")
    assert getenv_any(["FIRST", "SECOND"]) == "value"


def test_as_text_handles_non_string_values():
    assert _as_text(None) == ""
    assert _as_text({"a": 1}) == '{"a": 1}'
    assert _as_text(12) == "12"


def test_pretty_json_falls_back_to_json_string():
    assert '"a": 1' in _pretty_json({"a": 1})


def test_load_env_file_sets_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("SLACK_BOT_TOKEN=xoxb-test\nSLACK_CHANNEL=C123\n", encoding="utf-8")
    monkeypatch.delenv("SLACK_BOT_TOKEN", raising=False)
    monkeypatch.delenv("SLACK_CHANNEL", raising=False)

    load_env_file(str(env_file))

    assert os.environ["SLACK_BOT_TOKEN"] == "xoxb-test"
    assert os.environ["SLACK_CHANNEL"] == "C123"


def test_load_env_file_does_not_override_existing_value(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("SLACK_BOT_TOKEN=xoxb-test\n", encoding="utf-8")
    monkeypatch.setenv("SLACK_BOT_TOKEN", "existing")

    load_env_file(str(env_file))

    assert os.environ["SLACK_BOT_TOKEN"] == "existing"


def test_parse_args_uses_env_file_defaults(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("SLACK_BOT_TOKEN=xoxb-from-env\nSLACK_CHANNEL=CENV\n", encoding="utf-8")
    monkeypatch.delenv("SLACK_BOT_TOKEN", raising=False)
    monkeypatch.delenv("SLACK_CHANNEL", raising=False)

    args = parse_args(["--env-file", str(env_file)])

    assert args.token == "xoxb-from-env"
    assert args.channel == "CENV"


def test_main_returns_error_without_credentials(monkeypatch, capsys):
    monkeypatch.delenv("SLACK_BOT_TOKEN", raising=False)
    monkeypatch.delenv("SLACK_CHANNEL", raising=False)

    exit_code = main(["--env-file", "missing.env"], stdin=io.StringIO(""))

    assert exit_code == 2
    assert "need --token/--channel" in capsys.readouterr().err


def test_main_returns_error_without_session_log(monkeypatch, capsys, tmp_path):
    monkeypatch.setenv("SLACK_BOT_TOKEN", "xoxb-token")
    monkeypatch.setenv("SLACK_CHANNEL", "C123")

    exit_code = main(
        ["--env-file", "missing.env", "--sessions-dir", str(tmp_path), "--once"]
    )

    assert exit_code == 2
    assert "no Codex session log file found" in capsys.readouterr().err


def test_process_events_posts_root_assistant_and_finish():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(
            {
                "token": token,
                "channel": channel,
                "text": text,
                "thread_ts": thread_ts,
            }
        )
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        "\n".join(
            [
                '{"type":"turn.started"}',
                '{"type":"item.completed","item":{"type":"assistant_message","text":"hello"}}',
            ]
        )
    )

    exit_code = process_events(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        initial_prompt="fix failing test",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert exit_code == 0
    assert posts[0]["text"] == "root"
    assert posts[1]["thread_ts"] == "123.456"
    assert "*user*" in posts[1]["text"]
    assert "fix failing test" in posts[1]["text"]
    assert "*assistant*" in posts[2]["text"]
    assert "hello" in posts[2]["text"]
    assert "Codex run finished" in posts[3]["text"]


def test_process_events_does_not_post_turn_started():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    process_events(
        io.StringIO('{"type":"turn.started"}'),
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert len(posts) == 2
    assert posts[0] == "root"
    assert "Codex run finished" in posts[1]


def test_process_events_skips_invalid_json():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO("not-json\n\n")
    process_events(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert len(posts) == 2
    assert posts[0] == "root"
    assert "Codex run finished" in posts[1]


def test_process_events_includes_tools_when_enabled():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        '{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0,"stdout":"ok","stderr":""}}'
    )

    process_events(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        include_tools=True,
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert any("command_execution" in post for post in posts)
    assert any("COMMAND:\nls" in post for post in posts)


def test_process_events_ignores_tools_when_disabled():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        '{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0}}'
    )

    process_events(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        include_tools=False,
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert len(posts) == 2
    assert "Codex run finished" in posts[-1]


def test_process_events_handles_user_message():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        '{"type":"turn.started"}\n{"type":"item.completed","item":{"type":"user_message","text":"please fix it"}}'
    )

    process_events(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert any("*user*" in post for post in posts)
    assert any("please fix it" in post for post in posts)


def test_process_events_posts_concise_failure():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    process_events(
        io.StringIO('{"type":"turn.started"}\n{"type":"turn.failed"}'),
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert any("*system*" in post for post in posts)
    assert any("turn 1 failed" in post for post in posts)


def test_iter_follow_lines_reads_existing_content_once(tmp_path):
    log_file = tmp_path / "session.jsonl"
    log_file.write_text("line1\nline2\n", encoding="utf-8")

    lines = list(
        iter_follow_lines(
            log_file,
            once=True,
            start_at_end=False,
            sleep_func=lambda _: None,
        )
    )

    assert lines == ["line1\n", "line2\n"]


def test_iter_follow_lines_starts_at_end_when_following(tmp_path):
    log_file = tmp_path / "session.jsonl"
    log_file.write_text("old1\nold2\n", encoding="utf-8")

    lines = list(
        iter_follow_lines(
            log_file,
            once=True,
            start_at_end=True,
            sleep_func=lambda _: None,
        )
    )

    assert lines == []


def test_find_latest_session_file_selects_most_recent(tmp_path):
    older = tmp_path / "older.jsonl"
    newer_dir = tmp_path / "nested"
    newer_dir.mkdir()
    newer = newer_dir / "newer.jsonl"
    older.write_text("{}", encoding="utf-8")
    newer.write_text("{}", encoding="utf-8")
    os.utime(older, (1, 1))
    os.utime(newer, (2, 2))

    latest = find_latest_session_file(tmp_path)

    assert latest == newer


def test_is_tool_event_type_recognizes_command_execution():
    assert _is_tool_event_type("command_execution") is True
    assert _is_tool_event_type("other") is False


def test_format_tool_payload_formats_command():
    payload = {"command": ["ls", "-la"], "exit_code": 0, "stdout": "ok", "stderr": ""}
    text = _format_tool_payload(payload)
    assert "$ ls -la" in text
    assert "[exit_code] 0" in text
    assert "[stdout]" in text


def test_format_tool_payload_formats_generic_tool():
    payload = {"name": "web_search", "arguments": {"q": "x"}, "result": {"ok": True}}
    text = _format_tool_payload(payload)
    assert "[tool] web_search" in text
    assert "[args]" in text
    assert "[result]" in text


def test_process_codex_log_stream_posts_user_and_assistant_messages():
    posts = []
    counter = {"n": 0}

    def fake_post(token, channel, text, thread_ts=None):
        counter["n"] += 1
        ts = f"123.45{counter['n']}"
        posts.append({"text": text, "thread_ts": thread_ts, "ts": ts})
        return {"ok": True, "ts": ts}

    events = io.StringIO(
        "\n".join(
            [
                '{"type":"event_msg","payload":{"type":"user_message","message":"fix tests"}}',
                '{"type":"event_msg","payload":{"type":"agent_message","message":"working on it"}}',
            ]
        )
    )

    exit_code = process_codex_log_stream(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert exit_code == 0
    assert posts[0]["text"] == "root"
    assert posts[1]["thread_ts"] is None
    assert "*user*" in posts[1]["text"] and "fix tests" in posts[1]["text"]
    assert posts[2]["thread_ts"] == posts[1]["ts"]
    assert "*assistant*" in posts[2]["text"] and "working on it" in posts[2]["text"]


def test_process_codex_log_stream_posts_task_complete_message():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append({"text": text, "thread_ts": thread_ts})
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        '{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}'
    )

    process_codex_log_stream(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert any("*assistant*" in post["text"] and "done" in post["text"] for post in posts)


def test_process_codex_log_stream_posts_tool_when_enabled():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append({"text": text, "thread_ts": thread_ts})
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        '{"type":"event_msg","payload":{"type":"command_execution","command":"ls","stdout":"ok","exit_code":0}}'
    )

    process_codex_log_stream(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        include_tools=True,
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert any("*tool*" in post["text"] for post in posts)
    assert any("```" in post["text"] for post in posts)


def test_extract_events_reads_message_parts():
    obj = {
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "output_text", "text": "part one"},
                {"type": "output_text", "text": "part two"},
            ],
        },
    }

    events = extract_events(obj)

    assert ("assistant", "part one", "output_text") in events
    assert ("assistant", "part two", "output_text") in events


def test_extract_events_reads_payload_input_text():
    obj = {"type": "x", "payload": {"type": "input_text", "text": "hello"}}
    assert ("user", "hello", "input_text") in extract_events(obj)


def test_extract_events_reads_direct_output_text():
    obj = {"type": "output_text", "text": "done"}
    assert ("assistant", "done", "output_text") in extract_events(obj)


def test_extract_events_reads_nested_user_message():
    obj = {
        "type": "wrapper",
        "message": {
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "hello"},
        },
    }

    events = extract_events(obj)

    assert ("user", "hello", "input_text") in events


def test_extract_events_reads_tool_from_nested_payload():
    obj = {
        "type": "wrapper",
        "payload": {
            "type": "something",
            "tool_result": {"type": "tool_result", "name": "x", "output": {"ok": True}},
        },
    }

    events = extract_events(obj)

    assert any(kind == "tool" for kind, _, _ in events)


def test_process_codex_log_stream_deduplicates_same_message():
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append({"text": text, "thread_ts": thread_ts})
        return {"ok": True, "ts": "123.456"}

    events = io.StringIO(
        "\n".join(
            [
                '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}',
                '{"type":"event_msg","payload":{"type":"agent_message","message":"same"}}',
            ]
        )
    )

    process_codex_log_stream(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assistant_posts = [post for post in posts if "*assistant*" in post["text"]]
    assert len(assistant_posts) == 1


def test_process_codex_log_stream_starts_new_thread_for_each_user_message():
    posts = []
    counter = {"n": 0}

    def fake_post(token, channel, text, thread_ts=None):
        counter["n"] += 1
        ts = f"200.0{counter['n']}"
        posts.append({"text": text, "thread_ts": thread_ts, "ts": ts})
        return {"ok": True, "ts": ts}

    events = io.StringIO(
        "\n".join(
            [
                '{"type":"event_msg","payload":{"type":"user_message","message":"first"}}',
                '{"type":"event_msg","payload":{"type":"agent_message","message":"reply1"}}',
                '{"type":"event_msg","payload":{"type":"user_message","message":"second"}}',
                '{"type":"event_msg","payload":{"type":"agent_message","message":"reply2"}}',
            ]
        )
    )

    process_codex_log_stream(
        events,
        token="xoxb-token",
        channel="C123",
        root_text="root",
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    first_user = posts[1]
    first_reply = posts[2]
    second_user = posts[3]
    second_reply = posts[4]

    assert first_user["thread_ts"] is None
    assert first_reply["thread_ts"] == first_user["ts"]
    assert second_user["thread_ts"] is None
    assert second_reply["thread_ts"] == second_user["ts"]


@pytest.mark.parametrize(
    "item_type",
    ["file_change", "web_search", "something_else"],
)
def test_process_events_posts_other_tool_types(item_type):
    posts = []

    def fake_post(token, channel, text, thread_ts=None):
        posts.append(text)
        return {"ok": True, "ts": "123.456"}

    payload = f'{{"type":"item.completed","item":{{"type":"{item_type}","value":"x"}}}}'
    process_events(
        io.StringIO(payload),
        token="xoxb-token",
        channel="C123",
        root_text="root",
        include_tools=True,
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert len(posts) >= 2
