"""Tests for temporal layout engine (v2)."""

from datetime import datetime, timedelta, timezone
from pathlib import Path

from hornet.store import ChatStore, utc_now
from hornet.models import ChatLine
from hornet.temporal import TemporalEngine


def test_fade_and_snapshot(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    task = store.spawn("coordinator", "task", title="old-task")
    store.append_chat(task.id, ChatLine(role="user", text="hi", tokens=5))

    engine = TemporalEngine(store)
    snap = engine.snapshot(scope="global")
    assert any(n["id"] == task.id for n in snap["nodes"])
    assert snap["tokenSeries"]

    engine.add_bookmark("global", ["docs", "sync"], text="Batch reframed")
    bms = engine.load_bookmarks("global", zoom=2)
    assert bms and bms[0]["keywords"]


def test_subtree_scope(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    disc = store.spawn("coordinator", "discussion", title="disc")
    task = store.spawn(disc.id, "task", title="child-task")
    engine = TemporalEngine(store)
    snap = engine.snapshot(scope=f"node:{disc.id}")
    ids = {n["id"] for n in snap["nodes"]}
    assert disc.id in ids
    assert task.id in ids
