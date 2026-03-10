import io
import os

import pytest

from codex_notify.cli import (
    chunk_text,
    fmt_block,
    getenv_any,
    load_env_file,
    main,
    parse_args,
    process_events,
)


def test_chunk_text_splits_long_text():
    text = "a" * 10
    parts = list(chunk_text(text, max_len=4))
    assert parts == ["aaaa", "aaaa", "aa"]


def test_fmt_block_wraps_title_and_body():
    assert fmt_block("title", "body") == "*title*\n```body```"


def test_getenv_any_returns_first_match(monkeypatch):
    monkeypatch.delenv("FIRST", raising=False)
    monkeypatch.setenv("SECOND", "value")
    assert getenv_any(["FIRST", "SECOND"]) == "value"


def test_load_env_file_sets_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("SLACK_BOT_TOKEN=xoxb-test\nSLACK_CHANNEL=C123\n", encoding="utf-8")
    monkeypatch.delenv("SLACK_BOT_TOKEN", raising=False)
    monkeypatch.delenv("SLACK_CHANNEL", raising=False)

    load_env_file(str(env_file))

    assert os.environ["SLACK_BOT_TOKEN"] == "xoxb-test"
    assert os.environ["SLACK_CHANNEL"] == "C123"


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
        post_func=fake_post,
        sleep_func=lambda _: None,
    )

    assert exit_code == 0
    assert posts[0]["text"] == "root"
    assert posts[1]["thread_ts"] == "123.456"
    assert "turn 1 started" in posts[1]["text"]
    assert "assistant (turn 1)" in posts[2]["text"]
    assert "Codex run finished" in posts[3]["text"]


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

    assert any("user (turn 1)" in post for post in posts)
    assert any("please fix it" in post for post in posts)


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
