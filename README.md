# Hornet

DevCentr's lightweight agent harness — **D only**, **tgc** (thread-local GC) enabled by default, persisted node graph on disk, **Mixr** model routing.

| Phase | Ships |
| --- | --- |
| **v0** | `graph.json`, per-node `meta.json` + `chat.jsonl`, orchestrator metathread, CLI |
| **v0.5** | Mixr on-device + suppress lists; `/api/health`, OpenAI-compat stub, `/api/provider/*` for t3code |
| **v1** | Mixr router, wait-graph (`warn` default), HTTP desk (`hornet serve`) |
| **v2** | Temporal layout engine — scrubber, fade, heatmap, scoped bookmarks |
| **desk PM** | Status colors for `awaiting_user` / failed; **Mark completed** + **Archive** (`POST /api/hide`) |

## Changelog

See [CHANGELOG.adoc](CHANGELOG.adoc).

## Build

Requires [DUB](https://dub.pm/) and LDC/DMD. Thread-local GC via dependency on [`dlang-supplemental/tgc`](../../dlang-supplemental/tgc) (`Tgc_default` → `--DRT-gcopt=gc:tgc` embedded in the binary).

```powershell
cd $env:code\github.com\dev-centr\hornet
dub build
dub test
```

## Quick start

```powershell
.\hornet.exe init .\my-chat
.\hornet.exe spawn .\my-chat --parent=coordinator --type=task --title=docs-sync
.\hornet.exe serve .\my-chat --port=8765
```

Open http://127.0.0.1:8765 for the desk UI.

## Disk layout

Matches [actor-model-agentic-ui](https://docs.devcentr.org/agent-rules/actor-model-agentic-ui.html):

```
$CHAT_ROOT/
  graph.json
  orchestrator/meta.jsonl
  nodes/{id}/meta.json
  nodes/{id}/chat.jsonl
  timeline/bookmarks.jsonl
```

## Harness

Set `HARNESS_NAME = hornet` in `$CODE_ROOT/harness.md`.

## Architecture

- **Long-lived:** `hornet serve` — supervisor + HTTP desk (future: `hornetd` RPC for thin CLI clients).
- **One-shot:** CLI subcommands touch disk directly (git-shaped); no Python, no embedded interpreter per invoke.
- **tgc:** per-thread heaps; collections do not stop-the-world sibling threads — fits actor swarms + `@nogc` workers.
- **Discovery vs routing:** [Open Provider Registry / UniProvider](https://github.com/dev-centr/uniprovider) finds endpoints; **Mixr** chooses models. Prefer OPR manifests over hard-coding a single local runner brand.
