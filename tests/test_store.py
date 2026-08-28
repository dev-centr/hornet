"""Tests for v0 disk store."""

from pathlib import Path

from hornet.store import ChatStore
from hornet.models import ChatLine


def test_init_and_spawn(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    coord = store.init_session("Test")
    assert coord.id == "coordinator"

    task = store.spawn("coordinator", "task", title="docs-sync", reason="multi-repo")
    assert task.spawned_by == "coordinator"
    parent = store.load_node("coordinator")
    assert task.id in parent.spawned

    line = store.append_chat(task.id, ChatLine(role="user", text="hello"))
    assert line == 1
    chat = store.read_chat(task.id)
    assert chat[0]["text"] == "hello"

    meta = store.read_metathread()
    kinds = [m["kind"] for m in meta]
    assert "spawn" in kinds


def test_propose_spawn(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    child = store.propose_spawn_from_message("coordinator", "Also, we should fix the CLA thing")
    assert child is not None
    assert child.type == "discussion"


def test_disambiguation(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    child = store.propose_spawn_from_message(
        "coordinator",
        "Continue the merge or we could also refactor the timeline engine",
    )
    assert child is not None
    assert child.type == "disambiguation"
