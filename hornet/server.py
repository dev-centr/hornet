"""HTTP server + desk UI API (v1)."""

from __future__ import annotations

import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from hornet.mixr import Mixr
from hornet.models import ChatLine
from hornet.store import ChatStore
from hornet.temporal import TemporalEngine
from hornet.wait_graph import WaitGraph

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


class HornetHandler(BaseHTTPRequestHandler):
    store: ChatStore
    mixr: Mixr
    temporal: TemporalEngine

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return

    def _json(self, code: int, payload: object) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8") or "{}")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/" or path == "/index.html":
            return self._serve_file(WEB_DIR / "index.html", "text/html")
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            return self._serve_file(WEB_DIR / rel)

        if path == "/api/graph":
            nodes = [n.to_meta() for n in self.store.load_all_nodes() if not n.hidden]
            graph = self.store.load_graph().to_json()
            return self._json(200, {"graph": graph, "nodes": nodes})

        if path == "/api/metathread":
            limit = int(qs.get("limit", ["50"])[0])
            return self._json(200, {"lines": self.store.read_metathread(limit=limit)})

        if path.startswith("/api/nodes/") and path.endswith("/chat"):
            node_id = path.split("/")[3]
            limit = int(qs.get("limit", ["100"])[0])
            return self._json(200, {"lines": self.store.read_chat(node_id, limit=limit)})

        if path == "/api/temporal":
            scope = qs.get("scope", ["global"])[0]
            at = qs.get("at", [None])[0]
            zoom = float(qs.get("zoom", ["1"])[0])
            payload = self.temporal.snapshot(scope=scope, at_iso=at, zoom=zoom)
            return self._json(200, payload)

        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_json()

        if path == "/api/message":
            node_id = body["nodeId"]
            text = body["text"]
            role = body.get("role", "user")
            line_no = self.store.append_chat(node_id, ChatLine(role=role, text=text, tokens=len(text.split())))
            spawned = None
            if role == "user":
                spawned_node = self.store.propose_spawn_from_message(node_id, text)
                if spawned_node:
                    spawned = spawned_node.to_meta()
            return self._json(200, {"line": line_no, "spawned": spawned})

        if path == "/api/spawn":
            child = self.store.spawn(
                body["parentId"],
                body["type"],
                title=body.get("title", ""),
                topic=body.get("topic", ""),
                reason=body.get("reason", ""),
                disambiguation=bool(body.get("disambiguation")),
            )
            plan = self.mixr.route(child, job_hint=body.get("title", ""))
            self.mixr.apply_to_node(child, plan)
            self.store.save_node(child)
            self.store.append_metathread("route", {"node": child.id, **plan.to_dict()})
            return self._json(200, {"node": child.to_meta(), "route": plan.to_dict()})

        if path == "/api/status":
            node = self.store.set_status(body["nodeId"], body["status"], body.get("summary"))
            return self._json(200, {"node": node.to_meta()})

        if path == "/api/hide":
            node = self.store.hide_node(body["nodeId"], bool(body.get("hidden", True)))
            return self._json(200, {"node": node.to_meta()})

        if path == "/api/route":
            node = self.store.load_node(body["nodeId"])
            plan = self.mixr.route(node, job_hint=body.get("hint", ""))
            self.mixr.apply_to_node(node, plan)
            self.store.save_node(node)
            self.store.append_metathread("route", {"node": node.id, **plan.to_dict()})
            wg = WaitGraph(self.store)
            ok, checks = wg.can_proceed(node)
            return self._json(200, {"route": plan.to_dict(), "waitGraphOk": ok, "waitChecks": [c.__dict__ for c in checks]})

        if path == "/api/bookmark":
            kw = body.get("keywords") or []
            self.temporal.add_bookmark(body.get("scope", "global"), kw, body.get("text", ""), body.get("image"))
            return self._json(200, {"ok": True})

        self._json(404, {"error": "not found"})

    def _serve_file(self, file_path: Path, default_type: str = "application/octet-stream") -> None:
        if not file_path.is_file():
            self._json(404, {"error": "missing file"})
            return
        data = file_path.read_bytes()
        ctype = mimetypes.guess_type(str(file_path))[0] or default_type
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def run_server(chat_root: Path, host: str = "127.0.0.1", port: int = 8765, policy: str = "balanced") -> None:
    store = ChatStore(chat_root)
    if not store.list_node_ids():
        store.init_session("Hornet desk")

    # Seed demo tasks if only coordinator exists
    nodes = store.load_all_nodes()
    if len(nodes) <= 1:
        demos = [
            ("task", "docs-sync", "Merge docs#3 onto main", "running"),
            ("task", "bitwarden-22642", "Retry bitwarden#22642", "running"),
            ("task", "openshellorg-prohelp", "CLA blocked on org", "blocked"),
        ]
        for typ, title, summary, status in demos:
            t = store.spawn("coordinator", typ, title=title, reason="demo seed")
            store.set_status(t.id, status, summary)

    mixr = Mixr(policy=policy)  # type: ignore[arg-type]
    temporal = TemporalEngine(store)

    handler = HornetHandler
    handler.store = store
    handler.mixr = mixr
    handler.temporal = temporal

    server = ThreadingHTTPServer((host, port), handler)
    print(f"Hornet desk http://{host}:{port}  chat_root={chat_root}")
    server.serve_forever()
