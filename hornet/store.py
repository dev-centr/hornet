"""Disk-backed node graph store (v0)."""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from hornet.models import ChatLine, GraphIndex, NodeRecord, NodeType

MetaKind = Literal["message", "ref", "spawn", "route", "bookmark", "summary"]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:48] or "node"


class ChatStore:
    """Authoritative per-node disk store + orchestrator metathread."""

    def __init__(self, chat_root: Path) -> None:
        self.root = chat_root.resolve()
        self.nodes_dir = self.root / "nodes"
        self.orch_dir = self.root / "orchestrator"
        self.views_dir = self.root / "views"
        self.timeline_dir = self.root / "timeline"

    def ensure_layout(self) -> None:
        self.nodes_dir.mkdir(parents=True, exist_ok=True)
        self.orch_dir.mkdir(parents=True, exist_ok=True)
        self.views_dir.mkdir(parents=True, exist_ok=True)
        self.timeline_dir.mkdir(parents=True, exist_ok=True)
        meta_path = self.orch_dir / "meta.jsonl"
        if not meta_path.exists():
            meta_path.touch()

    @property
    def graph_path(self) -> Path:
        return self.root / "graph.json"

    def load_graph(self) -> GraphIndex:
        if not self.graph_path.exists():
            return GraphIndex()
        return GraphIndex.from_json(json.loads(self.graph_path.read_text(encoding="utf-8")))

    def save_graph(self, graph: GraphIndex) -> None:
        self.graph_path.write_text(json.dumps(graph.to_json(), indent=2) + "\n", encoding="utf-8")

    def node_dir(self, node_id: str) -> Path:
        return self.nodes_dir / node_id

    def load_node(self, node_id: str) -> NodeRecord:
        path = self.node_dir(node_id) / "meta.json"
        if not path.exists():
            raise KeyError(f"unknown node: {node_id}")
        return NodeRecord.from_meta(json.loads(path.read_text(encoding="utf-8")))

    def save_node(self, node: NodeRecord) -> None:
        nd = self.node_dir(node.id)
        nd.mkdir(parents=True, exist_ok=True)
        (nd / "meta.json").write_text(json.dumps(node.to_meta(), indent=2) + "\n", encoding="utf-8")

    def list_node_ids(self) -> list[str]:
        if not self.nodes_dir.exists():
            return []
        return sorted(p.name for p in self.nodes_dir.iterdir() if p.is_dir())

    def load_all_nodes(self) -> list[NodeRecord]:
        return [self.load_node(nid) for nid in self.list_node_ids()]

    def append_chat(self, node_id: str, line: ChatLine) -> int:
        """Append to chat.jsonl; return 1-based line number."""
        nd = self.node_dir(node_id)
        nd.mkdir(parents=True, exist_ok=True)
        chat_path = nd / "chat.jsonl"
        existing = 0
        if chat_path.exists():
            existing = sum(1 for _ in chat_path.open(encoding="utf-8"))
        record = {"role": line.role, "text": line.text, "tokens": line.tokens, "at": utc_now()}
        with chat_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        node = self.load_node(node_id)
        node.last_event_at = record["at"]
        node.last_touched_at = record["at"]
        self.save_node(node)
        return existing + 1

    def read_chat(self, node_id: str, limit: int | None = None) -> list[dict[str, Any]]:
        chat_path = self.node_dir(node_id) / "chat.jsonl"
        if not chat_path.exists():
            return []
        lines = [json.loads(l) for l in chat_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        if limit is not None:
            return lines[-limit:]
        return lines

    def append_metathread(self, kind: MetaKind, payload: dict[str, Any]) -> None:
        record = {"kind": kind, "at": utc_now(), **payload}
        with (self.orch_dir / "meta.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def read_metathread(self, limit: int | None = None) -> list[dict[str, Any]]:
        path = self.orch_dir / "meta.jsonl"
        if not path.exists():
            return []
        lines = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
        if limit is not None:
            return lines[-limit:]
        return lines

    def init_session(self, title: str = "Session") -> NodeRecord:
        self.ensure_layout()
        graph = self.load_graph()
        if self.list_node_ids():
            return self.load_node(graph.root)

        now = utc_now()
        coord = NodeRecord(
            id="coordinator",
            type="coordinator",
            address=str(self.nodes_dir / "coordinator"),
            status="running",
            title=title,
            topic=title,
            summary=f"Coordinator for {title}",
            created_at=now,
            last_event_at=now,
            last_touched_at=now,
        )
        self.save_node(coord)
        graph.root = coord.id
        graph.nodes[coord.id] = {"type": coord.type}
        self.save_graph(graph)
        self.append_metathread("summary", {"text": f"Hornet session started: {title}"})
        self.append_chat(coord.id, ChatLine(role="assistant", text=f"Coordinator online — {title}", tokens=12))
        return coord

    def _unique_id(self, base: str) -> str:
        graph = self.load_graph()
        candidate = base
        n = 2
        while candidate in graph.nodes:
            candidate = f"{base}-{n}"
            n += 1
        return candidate

    def spawn(
        self,
        parent_id: str,
        node_type: NodeType,
        *,
        title: str = "",
        topic: str = "",
        reason: str = "",
        disambiguation: bool = False,
    ) -> NodeRecord:
        parent = self.load_node(parent_id)
        now = utc_now()
        base = _slug(title or topic or node_type)
        if disambiguation:
            base = f"disambig-{base}"
        node_id = self._unique_id(base)

        child = NodeRecord(
            id=node_id,
            type="disambiguation" if disambiguation else node_type,
            address=str(self.nodes_dir / node_id),
            spawned_by=parent_id,
            status="idle",
            title=title or node_id,
            topic=topic or title or node_id,
            summary=reason or f"Spawned from {parent_id}",
            created_at=now,
            last_event_at=now,
            last_touched_at=now,
        )
        self.save_node(child)

        parent.spawned.append(node_id)
        parent.last_event_at = now
        self.save_node(parent)

        graph = self.load_graph()
        graph.nodes[node_id] = {"type": child.type, "spawnedBy": parent_id}
        self.save_graph(graph)

        marker = f"→ spawned {child.type} `{node_id}`" + (f": {reason}" if reason else "")
        line_no = self.append_chat(parent_id, ChatLine(role="routing", text=marker, tokens=0))
        self.append_metathread(
            "spawn",
            {"parent": parent_id, "child": node_id, "type": child.type, "parentLine": line_no, "reason": reason},
        )
        return child

    def set_status(self, node_id: str, status: str, summary: str | None = None) -> NodeRecord:
        node = self.load_node(node_id)
        node.status = status  # type: ignore[assignment]
        if summary is not None:
            node.summary = summary
        node.last_event_at = utc_now()
        self.save_node(node)
        self.append_metathread("summary", {"node": node_id, "status": status, "summary": node.summary})
        return node

    def hide_node(self, node_id: str, hidden: bool = True) -> NodeRecord:
        node = self.load_node(node_id)
        node.hidden = hidden
        self.save_node(node)
        return node

    def add_ref(self, node_id: str, line: int, summary: str) -> None:
        self.append_metathread("ref", {"node": node_id, "line": line, "summary": summary})

    def propose_spawn_from_message(
        self,
        node_id: str,
        user_text: str,
    ) -> NodeRecord | None:
        """Heuristic model-proposed spawn (v0 stub — keyword boundaries)."""
        lower = user_text.lower()
        markers = ["also,", "another idea", "separately", "side note", "new topic", "while we're at it"]
        if not any(m in lower for m in markers):
            return None
        if " or " in lower and "continue" in lower:
            return self.spawn(
                node_id,
                "disambiguation",
                title="boundary",
                topic=user_text[:120],
                reason="Mixed continuation + new ideas",
                disambiguation=True,
            )
        return self.spawn(
            node_id,
            "discussion",
            title=user_text[:40],
            topic=user_text[:200],
            reason="Model-proposed spawn on drift",
        )
