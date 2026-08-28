"""Tests for Mixr and wait graph (v1)."""

from pathlib import Path

from hornet.mixr import Mixr
from hornet.models import NodeRecord, WaitOn
from hornet.store import ChatStore
from hornet.wait_graph import WaitGraph


def test_mixr_routes_by_type() -> None:
    mixr = Mixr(policy="balanced")
    coord = NodeRecord(id="c", type="coordinator", address="/x")
    task = NodeRecord(id="t", type="task", address="/y")
    plan_c = mixr.route(coord)
    plan_t = mixr.route(task, job_hint="merge PR")
    assert "glm" in plan_c.model.lower() or "z-ai" in plan_c.model
    assert plan_t.model != plan_c.model or plan_t.catalog_key != plan_c.catalog_key


def test_wait_graph_warn_allows_stale(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    a = store.spawn("coordinator", "task", title="a")
    b = store.spawn("coordinator", "task", title="b")
    store.set_status(a.id, "running")
    node_b = store.load_node(b.id)
    node_b.wait_on = [WaitOn(node=a.id, mode="warn")]
    store.save_node(node_b)
    wg = WaitGraph(store)
    ok, checks = wg.can_proceed(node_b)
    assert ok
    assert any("WARN" in c.message for c in checks)


def test_wait_graph_enforce_blocks(tmp_path: Path) -> None:
    store = ChatStore(tmp_path)
    store.init_session()
    a = store.spawn("coordinator", "task", title="a")
    b = store.spawn("coordinator", "task", title="b")
    store.set_status(a.id, "running")
    node_b = store.load_node(b.id)
    node_b.wait_on = [WaitOn(node=a.id, mode="enforce")]
    store.save_node(node_b)
    wg = WaitGraph(store)
    ok, _ = wg.can_proceed(node_b)
    assert not ok
