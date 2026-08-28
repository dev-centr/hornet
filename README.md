# Hornet

DevCentr's lightweight agent harness — persisted **node graph** on disk, **Mixr** model routing, actor-model UI.

| Phase | Ships |
| --- | --- |
| **v0** | `graph.json`, per-node `meta.json` + `chat.jsonl`, orchestrator metathread, spawn API |
| **v1** | Mixr router, wait-graph (`warn` default), HTTP + grid/fork web UI |
| **v2** | Temporal layout engine — scrubber, fade, bookmarks, heatmap |

## Quick start

```powershell
cd $env:code\github.com\dev-centr\hornet
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e ".[dev]"
hornet init ./my-chat
hornet spawn my-chat --parent coordinator --type task --title "Sync docs"
hornet serve my-chat --port 8765
```

Open http://localhost:8765 for the desk UI.

## Disk layout

Matches [actor-model-agentic-ui](https://docs.devcentr.org/agent-rules/actor-model-agentic-ui.html):

```
$CHAT_ROOT/
  graph.json
  orchestrator/meta.jsonl
  nodes/{id}/meta.json
  nodes/{id}/chat.jsonl
  timeline/bookmarks.jsonl   # v2
```

## Harness

Set `HARNESS_NAME = hornet` in `$CODE_ROOT/harness.md`. See `dev-centr/agent-rules` docs **Agent harness (Hornet)**.
