"""Mixr — model routing meta-agent (v1)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from hornet.models import NodeRecord, NodeType

Policy = Literal["balanced", "cheap", "quality", "byok-only"]

# Catalog entries — real providers wired later; Mixr picks from this table.
MODEL_CATALOG: dict[str, dict[str, str]] = {
    "coordinator-voice": {
        "model": "z-ai/glm-latest",
        "provider": "openrouter",
        "max_tokens": "32000",
        "reason": "Long context coordinator / summarization",
    },
    "task-coding": {
        "model": "anthropic/claude-sonnet-4",
        "provider": "openrouter",
        "max_tokens": "16000",
        "reason": "Reliable tool use for bounded jobs",
    },
    "discussion-explore": {
        "model": "google/gemini-2.5-flash",
        "provider": "openrouter",
        "max_tokens": "16000",
        "reason": "Fast exploratory discussion",
    },
    "disambiguation-fast": {
        "model": "openai/gpt-4.1-nano",
        "provider": "openrouter",
        "max_tokens": "4096",
        "reason": "Cheap boundary resolution",
    },
    "router-self": {
        "model": "openai/gpt-4.1-nano",
        "provider": "openrouter",
        "max_tokens": "1024",
        "reason": "Mixr routing call",
    },
}

POLICY_OVERRIDES: dict[Policy, dict[NodeType, str]] = {
    "balanced": {
        "coordinator": "coordinator-voice",
        "task": "task-coding",
        "discussion": "discussion-explore",
        "disambiguation": "disambiguation-fast",
    },
    "cheap": {
        "coordinator": "discussion-explore",
        "task": "discussion-explore",
        "discussion": "disambiguation-fast",
        "disambiguation": "disambiguation-fast",
    },
    "quality": {
        "coordinator": "coordinator-voice",
        "task": "task-coding",
        "discussion": "task-coding",
        "disambiguation": "discussion-explore",
    },
    "byok-only": {
        "coordinator": "coordinator-voice",
        "task": "task-coding",
        "discussion": "discussion-explore",
        "disambiguation": "disambiguation-fast",
    },
}


@dataclass
class RoutePlan:
    model: str
    provider: str
    max_tokens: int
    reason: str
    catalog_key: str

    def to_dict(self) -> dict:
        return {
            "model": self.model,
            "provider": self.provider,
            "maxTokens": self.max_tokens,
            "reason": self.reason,
            "catalogKey": self.catalog_key,
        }


class Mixr:
    """Cursor Auto-shaped router — assigns models per node invocation."""

    def __init__(self, policy: Policy = "balanced") -> None:
        self.policy = policy

    def route(self, node: NodeRecord, *, job_hint: str = "") -> RoutePlan:
        key_map = POLICY_OVERRIDES[self.policy]
        catalog_key = key_map.get(node.type, "discussion-explore")
        if job_hint and "merge" in job_hint.lower():
            catalog_key = "task-coding"
        entry = MODEL_CATALOG[catalog_key]
        return RoutePlan(
            model=entry["model"],
            provider=entry["provider"],
            max_tokens=int(entry["max_tokens"]),
            reason=entry["reason"] + (f"; hint={job_hint}" if job_hint else ""),
            catalog_key=catalog_key,
        )

    def route_router_call(self) -> RoutePlan:
        entry = MODEL_CATALOG["router-self"]
        return RoutePlan(
            model=entry["model"],
            provider=entry["provider"],
            max_tokens=int(entry["max_tokens"]),
            reason=entry["reason"],
            catalog_key="router-self",
        )

    def apply_to_node(self, node: NodeRecord, plan: RoutePlan) -> None:
        node.mixr_model = plan.model
        node.mixr_reason = plan.reason
