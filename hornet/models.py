"""Node graph structs — 1:1 with disk JSON."""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Literal

NodeType = Literal["coordinator", "discussion", "task", "disambiguation"]
NodeStatus = Literal["idle", "running", "blocked", "done", "failed", "awaiting_user"]
WaitMode = Literal["warn", "enforce"]

TERMINAL_STATUSES = frozenset({"done", "failed"})


@dataclass
class WaitOn:
    node: str
    mode: WaitMode = "warn"


@dataclass
class ChatLine:
    role: Literal["user", "assistant", "system", "routing"]
    text: str
    tokens: int = 0


@dataclass
class NodeRecord:
    id: str
    type: NodeType
    address: str
    status: NodeStatus = "idle"
    summary: str = ""
    spawned_by: str | None = None
    spawned: list[str] = field(default_factory=list)
    related: list[dict[str, str]] = field(default_factory=list)
    wait_on: list[WaitOn] = field(default_factory=list)
    view_epoch: int | None = None
    awaiting_user: bool = False
    hidden: bool = False
    title: str = ""
    topic: str = ""
    mixr_model: str | None = None
    mixr_reason: str | None = None
    last_event_at: str | None = None
    last_touched_at: str | None = None
    created_at: str | None = None

    def to_meta(self) -> dict[str, Any]:
        d = asdict(self)
        d["spawnedBy"] = d.pop("spawned_by")
        d["spawned"] = d.pop("spawned")
        d["waitOn"] = [{"node": w["node"], "mode": w["mode"]} for w in d.pop("wait_on")]
        d["viewEpoch"] = d.pop("view_epoch")
        d["awaitingUser"] = d.pop("awaiting_user")
        d["mixrModel"] = d.pop("mixr_model")
        d["mixrReason"] = d.pop("mixr_reason")
        d["lastEventAt"] = d.pop("last_event_at")
        d["lastTouchedAt"] = d.pop("last_touched_at")
        d["createdAt"] = d.pop("created_at")
        return d

    @classmethod
    def from_meta(cls, data: dict[str, Any]) -> NodeRecord:
        wait_raw = data.get("waitOn") or []
        return cls(
            id=data["id"],
            type=data["type"],
            address=data["address"],
            status=data.get("status", "idle"),
            summary=data.get("summary", ""),
            spawned_by=data.get("spawnedBy"),
            spawned=list(data.get("spawned") or []),
            related=list(data.get("related") or []),
            wait_on=[WaitOn(node=w["node"], mode=w.get("mode", "warn")) for w in wait_raw],
            view_epoch=data.get("viewEpoch"),
            awaiting_user=bool(data.get("awaitingUser")),
            hidden=bool(data.get("hidden")),
            title=data.get("title", ""),
            topic=data.get("topic", ""),
            mixr_model=data.get("mixrModel"),
            mixr_reason=data.get("mixrReason"),
            last_event_at=data.get("lastEventAt"),
            last_touched_at=data.get("lastTouchedAt"),
            created_at=data.get("createdAt"),
        )


@dataclass
class GraphIndex:
    version: int = 1
    root: str = "coordinator"
    nodes: dict[str, dict[str, str]] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        return {"version": self.version, "root": self.root, "nodes": self.nodes}

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> GraphIndex:
        if not data:
            return cls()
        return cls(
            version=data.get("version", 1),
            root=data.get("root", "coordinator"),
            nodes=dict(data.get("nodes") or {}),
        )
