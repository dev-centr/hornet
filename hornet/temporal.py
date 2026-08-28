"""Temporal layout view engine (v2)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from hornet.models import NodeRecord, TERMINAL_STATUSES
from hornet.store import ChatStore, utc_now


def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


class TemporalEngine:
    """Reusable timeline widget — global or subtree scope."""

    FADE_HOURS = 48

    def __init__(self, store: ChatStore) -> None:
        self.store = store
        self.bookmarks_path = store.timeline_dir / "bookmarks.jsonl"

    def _scope_nodes(self, scope: str) -> list[NodeRecord]:
        all_nodes = self.store.load_all_nodes()
        if scope == "global":
            return all_nodes
        if scope.startswith("node:"):
            root_id = scope.split(":", 1)[1]
            ids = self._subtree_ids(root_id)
            return [n for n in all_nodes if n.id in ids]
        return all_nodes

    def _subtree_ids(self, root_id: str) -> set[str]:
        out = {root_id}
        changed = True
        while changed:
            changed = False
            for n in self.store.load_all_nodes():
                if n.spawned_by in out and n.id not in out:
                    out.add(n.id)
                    changed = True
        return out

    def token_series(self, scope: str = "global") -> list[dict[str, Any]]:
        series: list[dict[str, Any]] = []
        for node in self._scope_nodes(scope):
            for line in self.store.read_chat(node.id):
                at = line.get("at")
                if not at:
                    continue
                series.append({"at": at, "tokens": line.get("tokens", 0), "node": node.id})
        series.sort(key=lambda x: x["at"])
        return series

    def fade_opacity(self, node: NodeRecord, at: datetime | None = None) -> float:
        if node.awaiting_user or node.status in TERMINAL_STATUSES:
            return 1.0
        ref = at or datetime.now(timezone.utc)
        last = parse_iso(node.last_touched_at)
        if not last:
            return 0.35
        if last.tzinfo is None:
            last = last.replace(tzinfo=timezone.utc)
        hours = (ref - last).total_seconds() / 3600
        if hours <= 1:
            return 1.0
        if hours >= self.FADE_HOURS:
            return 0.2
        return max(0.2, 1.0 - (hours / self.FADE_HOURS) * 0.8)

    def add_bookmark(
        self,
        scope: str,
        keywords: list[str],
        text: str = "",
        image: str | None = None,
    ) -> None:
        record = {
            "scope": scope,
            "at": utc_now(),
            "keywords": keywords,
            "text": text,
            "image": image,
        }
        with self.bookmarks_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.store.append_metathread("bookmark", record)

    def load_bookmarks(self, scope: str = "global", zoom: float = 1.0) -> list[dict[str, Any]]:
        if not self.bookmarks_path.exists():
            return []
        lines = [json.loads(l) for l in self.bookmarks_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        scoped = [b for b in lines if b.get("scope") == scope or scope == "global"]
        # Map-style: more zoom → more keywords per bookmark
        max_kw = max(1, int(zoom * 3))
        out = []
        for b in scoped:
            kws = list(b.get("keywords") or [])[:max_kw]
            out.append({**b, "keywords": kws})
        return out

    def snapshot(
        self,
        scope: str = "global",
        at_iso: str | None = None,
        zoom: float = 1.0,
    ) -> dict[str, Any]:
        at = parse_iso(at_iso) or datetime.now(timezone.utc)
        nodes = self._scope_nodes(scope)
        visible = []
        for n in nodes:
            if n.hidden:
                continue
            last = parse_iso(n.last_event_at)
            if last and last.tzinfo is None:
                last = last.replace(tzinfo=timezone.utc)
            if last and last > at:
                continue
            visible.append(
                {
                    **n.to_meta(),
                    "opacity": self.fade_opacity(n, at),
                }
            )
        tokens = [t for t in self.token_series(scope) if parse_iso(t["at"]) and parse_iso(t["at"]) <= at]
        return {
            "scope": scope,
            "at": at.isoformat(),
            "zoom": zoom,
            "nodes": visible,
            "tokenSeries": tokens,
            "bookmarks": self.load_bookmarks(scope, zoom),
            "heatmap": self._heatmap_buckets(tokens),
        }

    def _heatmap_buckets(self, tokens: list[dict[str, Any]], buckets: int = 24) -> list[float]:
        if not tokens:
            return [0.0] * buckets
        counts = [0.0] * buckets
        for t in tokens:
            dt = parse_iso(t["at"])
            if not dt:
                continue
            idx = dt.hour % buckets
            counts[idx] += t.get("tokens", 0)
        peak = max(counts) or 1.0
        return [c / peak for c in counts]
