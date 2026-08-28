"""CLI for Hornet v0."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from hornet.store import ChatStore
from hornet.models import ChatLine


def cmd_init(args: argparse.Namespace) -> int:
    store = ChatStore(Path(args.chat_root))
    coord = store.init_session(args.title)
    print(json.dumps({"root": coord.id, "path": str(store.root)}, indent=2))
    return 0


def cmd_spawn(args: argparse.Namespace) -> int:
    store = ChatStore(Path(args.chat_root))
    child = store.spawn(
        args.parent,
        args.type,
        title=args.title or "",
        topic=args.topic or args.title or "",
        reason=args.reason or "",
        disambiguation=args.disambiguation,
    )
    print(json.dumps({"id": child.id, "type": child.type, "address": child.address}, indent=2))
    return 0


def cmd_message(args: argparse.Namespace) -> int:
    store = ChatStore(Path(args.chat_root))
    line_no = store.append_chat(args.node, ChatLine(role=args.role, text=args.text, tokens=len(args.text.split())))
    if args.role == "user" and args.propose_spawn:
        spawned = store.propose_spawn_from_message(args.node, args.text)
        if spawned:
            print(json.dumps({"spawned": spawned.id, "line": line_no}, indent=2))
            return 0
    print(json.dumps({"line": line_no}, indent=2))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    store = ChatStore(Path(args.chat_root))
    node = store.set_status(args.node, args.status, args.summary)
    print(json.dumps({"id": node.id, "status": node.status, "summary": node.summary}, indent=2))
    return 0


def cmd_graph(args: argparse.Namespace) -> int:
    store = ChatStore(Path(args.chat_root))
    nodes = store.load_all_nodes()
    print(json.dumps([n.to_meta() for n in nodes], indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hornet", description="DevCentr Hornet harness")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="Initialize $CHAT_ROOT")
    p_init.add_argument("chat_root")
    p_init.add_argument("--title", default="Hornet session")
    p_init.set_defaults(func=cmd_init)

    p_spawn = sub.add_parser("spawn", help="Spawn child node")
    p_spawn.add_argument("chat_root")
    p_spawn.add_argument("--parent", required=True)
    p_spawn.add_argument("--type", required=True, choices=["discussion", "task", "disambiguation"])
    p_spawn.add_argument("--title", default="")
    p_spawn.add_argument("--topic", default="")
    p_spawn.add_argument("--reason", default="")
    p_spawn.add_argument("--disambiguation", action="store_true")
    p_spawn.set_defaults(func=cmd_spawn)

    p_msg = sub.add_parser("message", help="Append chat line")
    p_msg.add_argument("chat_root")
    p_msg.add_argument("--node", required=True)
    p_msg.add_argument("--role", default="user", choices=["user", "assistant", "system"])
    p_msg.add_argument("--text", required=True)
    p_msg.add_argument("--propose-spawn", action="store_true")
    p_msg.set_defaults(func=cmd_message)

    p_st = sub.add_parser("status", help="Set node status")
    p_st.add_argument("chat_root")
    p_st.add_argument("--node", required=True)
    p_st.add_argument("--status", required=True)
    p_st.add_argument("--summary", default=None)
    p_st.set_defaults(func=cmd_status)

    p_gr = sub.add_parser("graph", help="Dump all nodes")
    p_gr.add_argument("chat_root")
    p_gr.set_defaults(func=cmd_graph)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
