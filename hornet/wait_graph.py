"""Wait graph — warn / enforce sibling mailbox gating (v1)."""

from __future__ import annotations

from dataclasses import dataclass

from hornet.models import NodeRecord, TERMINAL_STATUSES, WaitMode
from hornet.store import ChatStore


@dataclass
class WaitCheck:
    node_id: str
    mode: WaitMode
    ok: bool
    status: str
    message: str


class WaitGraph:
    def __init__(self, store: ChatStore, default_mode: WaitMode = "warn") -> None:
        self.store = store
        self.default_mode = default_mode

    def check(self, node: NodeRecord) -> list[WaitCheck]:
        results: list[WaitCheck] = []
        subs = node.wait_on or []
        for sub in subs:
            mode = sub.mode or self.default_mode
            try:
                sibling = self.store.load_node(sub.node)
            except KeyError:
                results.append(
                    WaitCheck(sub.node, mode, False, "missing", f"Unknown node {sub.node}")
                )
                continue
            terminal = sibling.status in TERMINAL_STATUSES
            if terminal:
                results.append(
                    WaitCheck(sub.node, mode, True, sibling.status, "Terminal — safe to read")
                )
            elif mode == "warn":
                results.append(
                    WaitCheck(
                        sub.node,
                        mode,
                        True,
                        sibling.status,
                        f"WARN: mailbox may be stale ({sibling.status})",
                    )
                )
            else:
                results.append(
                    WaitCheck(
                        sub.node,
                        mode,
                        False,
                        sibling.status,
                        f"ENFORCE: blocked until terminal (now {sibling.status})",
                    )
                )
        return results

    def can_proceed(self, node: NodeRecord) -> tuple[bool, list[WaitCheck]]:
        checks = self.check(node)
        blocked = [c for c in checks if not c.ok]
        return len(blocked) == 0, checks
