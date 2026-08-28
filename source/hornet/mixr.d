module hornet.mixr;

import hornet.models;

import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue;
import std.string : toLower;

enum Policy : string
{
    balanced = "balanced",
    cheap = "cheap",
    quality = "quality",
    byokOnly = "byok-only",
}

struct RoutePlan
{
    string model;
    string provider;
    int maxTokens;
    string reason;
    string catalogKey;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["model"] = JSONValue(model);
        o["provider"] = JSONValue(provider);
        o["maxTokens"] = JSONValue(maxTokens);
        o["reason"] = JSONValue(reason);
        o["catalogKey"] = JSONValue(catalogKey);
        return o;
    }
}

struct Mixr
{
    Policy policy = Policy.balanced;

    RoutePlan route(ref const NodeRecord node, string jobHint = "") const
    {
        string catalogKey = catalogForType(node.type);
        if (jobHint.length && canFind(jobHint.toLower, "merge"))
            catalogKey = "task-coding";
        return planFromCatalog(catalogKey, jobHint);
    }

    RoutePlan routeRouterCall() const
    {
        return planFromCatalog("router-self", "");
    }

    void applyToNode(ref NodeRecord node, ref const RoutePlan plan)
    {
        node.mixrModel = plan.model;
        node.mixrReason = plan.reason;
    }

private:
    string catalogForType(NodeType t) const
    {
        final switch (policy)
        {
        case Policy.balanced:
            final switch (t)
            {
            case NodeType.coordinator: return "coordinator-voice";
            case NodeType.task: return "task-coding";
            case NodeType.discussion: return "discussion-explore";
            case NodeType.disambiguation: return "disambiguation-fast";
            }
        case Policy.cheap:
            final switch (t)
            {
            case NodeType.coordinator:
            case NodeType.task: return "discussion-explore";
            case NodeType.discussion:
            case NodeType.disambiguation: return "disambiguation-fast";
            }
        case Policy.quality:
            final switch (t)
            {
            case NodeType.coordinator: return "coordinator-voice";
            case NodeType.task: return "task-coding";
            case NodeType.discussion: return "task-coding";
            case NodeType.disambiguation: return "discussion-explore";
            }
        case Policy.byokOnly:
            final switch (t)
            {
            case NodeType.coordinator: return "coordinator-voice";
            case NodeType.task: return "task-coding";
            case NodeType.discussion: return "discussion-explore";
            case NodeType.disambiguation: return "disambiguation-fast";
            }
        }
    }

    RoutePlan planFromCatalog(string key, string jobHint) const
    {
        RoutePlan p;
        p.catalogKey = key;
        switch (key)
        {
        case "coordinator-voice":
            p.model = "z-ai/glm-latest";
            p.provider = "openrouter";
            p.maxTokens = 32000;
            p.reason = "Long context coordinator / summarization";
            break;
        case "task-coding":
            p.model = "anthropic/claude-sonnet-4";
            p.provider = "openrouter";
            p.maxTokens = 16000;
            p.reason = "Reliable tool use for bounded jobs";
            break;
        case "discussion-explore":
            p.model = "google/gemini-2.5-flash";
            p.provider = "openrouter";
            p.maxTokens = 16000;
            p.reason = "Fast exploratory discussion";
            break;
        case "disambiguation-fast":
            p.model = "openai/gpt-4.1-nano";
            p.provider = "openrouter";
            p.maxTokens = 4096;
            p.reason = "Cheap boundary resolution";
            break;
        case "router-self":
            p.model = "openai/gpt-4.1-nano";
            p.provider = "openrouter";
            p.maxTokens = 1024;
            p.reason = "Mixr routing call";
            break;
        default:
            return planFromCatalog("discussion-explore", jobHint);
        }
        if (jobHint.length)
            p.reason ~= "; hint=" ~ jobHint;
        return p;
    }
}

Policy parsePolicy(string s)
{
    switch (s)
    {
    case "cheap": return Policy.cheap;
    case "quality": return Policy.quality;
    case "byok-only": return Policy.byokOnly;
    default: return Policy.balanced;
    }
}

NodeType parseNodeType(string s)
{
    switch (s)
    {
    case "discussion": return NodeType.discussion;
    case "task": return NodeType.task;
    case "disambiguation": return NodeType.disambiguation;
    default: return NodeType.coordinator;
    }
}

NodeStatus parseNodeStatus(string s)
{
    switch (s)
    {
    case "running": return NodeStatus.running;
    case "blocked": return NodeStatus.blocked;
    case "done": return NodeStatus.done;
    case "failed": return NodeStatus.failed;
    case "awaiting_user": return NodeStatus.awaitingUser;
    default: return NodeStatus.idle;
    }
}
