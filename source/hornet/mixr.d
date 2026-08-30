module hornet.mixr;

import hornet.models;

import core.time : seconds;

import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.string : strip, toLower;

enum Policy : string
{
    balanced = "balanced",
    cheap = "cheap",
    quality = "quality",
    byokOnly = "byok-only",
}

/// Where Mixr's own classify call runs.
enum RouterPlacement : string
{
    /// Prefer local OpenAI-compat router (default).
    onDevice = "on-device",
    /// Always use remote API nano-class for Mixr self-calls.
    api = "api",
    /// on-device when RAM ok and local server reachable; else api.
    auto_ = "auto",
}

struct RoutePlan
{
    string model;
    string provider;
    int maxTokens;
    string reason;
    string catalogKey;
    bool suppressedBlocked;
    string routerPlacement; /// on-device | api | heuristic

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["model"] = JSONValue(model);
        o["provider"] = JSONValue(provider);
        o["maxTokens"] = JSONValue(maxTokens);
        o["reason"] = JSONValue(reason);
        o["catalogKey"] = JSONValue(catalogKey);
        o["suppressedBlocked"] = JSONValue(suppressedBlocked);
        if (routerPlacement.length)
            o["routerPlacement"] = JSONValue(routerPlacement);
        return o;
    }
}

struct MixrConfig
{
    Policy policy = Policy.balanced;
    RouterPlacement router = RouterPlacement.onDevice;
    string routerBaseUrl = "http://127.0.0.1:11434/v1";
    string routerModel = "mixr-router";
    int routerRamMinMb = 2048;
    string[] suppressProviders = ["anthropic"];
    string[] suppressModels;
    /// off | explicit-only — suppressed routes never chosen unless allowSuppressed.
    string allowSuppressed = "explicit-only";
}

struct Mixr
{
    MixrConfig config;

    @property Policy policy() const
    {
        return config.policy;
    }

    @property void policy(Policy p)
    {
        config.policy = p;
    }

    RoutePlan route(ref const NodeRecord node, string jobHint = "", bool allowSuppressed = false)
    {
        string catalogKey = catalogForType(node.type);
        if (jobHint.length && canFind(jobHint.toLower, "merge"))
            catalogKey = "task-coding";
        if (jobHint.length && (canFind(jobHint.toLower, "scaffold")
                || canFind(jobHint.toLower, "architect")))
            catalogKey = "task-architecture";
        return planFromCatalog(catalogKey, jobHint, allowSuppressed);
    }

    RoutePlan routeRouterCall(bool allowSuppressed = false)
    {
        auto placement = resolveRouterPlacement();
        if (placement == "on-device")
        {
            auto local = tryLocalRouterClassify();
            if (local.model.length)
            {
                local.routerPlacement = "on-device";
                return filterSuppressed(local, allowSuppressed);
            }
        }
        auto plan = planFromCatalog("router-self", "", allowSuppressed);
        plan.routerPlacement = placement == "on-device" ? "heuristic" : placement;
        if (placement == "on-device" && plan.reason.length)
            plan.reason ~= "; local router unreachable — catalog fallback";
        return plan;
    }

    void applyToNode(ref NodeRecord node, ref const RoutePlan plan)
    {
        node.mixrModel = plan.model;
        node.mixrReason = plan.reason;
    }

    bool isProviderSuppressed(string provider) const
    {
        auto p = provider.toLower;
        foreach (s; config.suppressProviders)
            if (s.toLower == p)
                return true;
        return false;
    }

    bool isModelSuppressed(string model) const
    {
        auto m = model.toLower;
        foreach (s; config.suppressModels)
            if (s.length && canFind(m, s.toLower))
                return true;
        return false;
    }

    JSONValue statusJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["policy"] = JSONValue(cast(string) config.policy);
        o["router"] = JSONValue(cast(string) config.router);
        o["routerBaseUrl"] = JSONValue(config.routerBaseUrl);
        o["routerModel"] = JSONValue(config.routerModel);
        o["routerRamMinMb"] = JSONValue(config.routerRamMinMb);
        o["availableRamMb"] = JSONValue(availableRamMb());
        o["routerPlacement"] = JSONValue(resolveRouterPlacement());
        JSONValue sp = JSONValue.emptyArray;
        foreach (p; config.suppressProviders)
            sp.array ~= JSONValue(p);
        o["suppressProviders"] = sp;
        JSONValue sm = JSONValue.emptyArray;
        foreach (m; config.suppressModels)
            sm.array ~= JSONValue(m);
        o["suppressModels"] = sm;
        o["allowSuppressed"] = JSONValue(config.allowSuppressed);
        return o;
    }

private:
    string catalogForType(NodeType t) const
    {
        final switch (config.policy)
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
            case NodeType.task: return "task-architecture";
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

    RoutePlan planFromCatalog(string key, string jobHint, bool allowSuppressed) const
    {
        RoutePlan p;
        p.catalogKey = key;
        p.routerPlacement = "heuristic";
        switch (key)
        {
        case "coordinator-voice":
            // Tier 2/3 long-context voice — GLM class
            p.model = "z-ai/glm-5.3";
            p.provider = "openrouter";
            p.maxTokens = 32000;
            p.reason = "Long-context coordinator / summarization (GLM)";
            break;
        case "task-coding":
            // Tier 2 agentic — MiniMax / Kimi / GLM (never Anthropic by default)
            p.model = "minimax/minimax-m3";
            p.provider = "openrouter";
            p.maxTokens = 16000;
            p.reason = "Agentic multi-file / tool loops (MiniMax M3)";
            break;
        case "task-architecture":
            // Tier 3 scaffolding
            p.model = "z-ai/glm-5.3";
            p.provider = "openrouter";
            p.maxTokens = 32000;
            p.reason = "Whole-system architecture / scaffolding (GLM-5.3)";
            break;
        case "discussion-explore":
            // Tier 1 flash
            p.model = "z-ai/glm-5.3-flash";
            p.provider = "openrouter";
            p.maxTokens = 16000;
            p.reason = "Fast exploratory discussion (GLM Flash)";
            break;
        case "disambiguation-fast":
            p.model = "deepseek/deepseek-chat";
            p.provider = "openrouter";
            p.maxTokens = 4096;
            p.reason = "Cheap boundary resolution";
            break;
        case "router-self":
            p.model = config.routerModel.length ? config.routerModel : "mixr-router";
            p.provider = "local";
            p.maxTokens = 1024;
            p.reason = "Mixr routing classify";
            break;
        default:
            return planFromCatalog("discussion-explore", jobHint, allowSuppressed);
        }
        if (jobHint.length)
            p.reason ~= "; hint=" ~ jobHint;
        return filterSuppressed(p, allowSuppressed);
    }

    RoutePlan filterSuppressed(RoutePlan p, bool allowSuppressed) const
    {
        const blocked = isProviderSuppressed(p.provider) || isModelSuppressed(p.model);
        if (!blocked)
        {
            p.suppressedBlocked = false;
            return p;
        }
        if (allowSuppressed && config.allowSuppressed == "explicit-only")
        {
            p.suppressedBlocked = false;
            p.reason ~= "; explicit override of suppress list";
            return p;
        }
        // Fall back to a non-suppressed flash tier
        p.suppressedBlocked = true;
        p.model = "z-ai/glm-5.3-flash";
        p.provider = "openrouter";
        p.catalogKey = "discussion-explore";
        p.maxTokens = 16000;
        p.reason ~= "; suppressed route blocked — fell back to GLM Flash";
        return p;
    }

    string resolveRouterPlacement() const
    {
        final switch (config.router)
        {
        case RouterPlacement.onDevice:
            if (availableRamMb() < config.routerRamMinMb)
                return "api";
            return "on-device";
        case RouterPlacement.api:
            return "api";
        case RouterPlacement.auto_:
            if (availableRamMb() < config.routerRamMinMb)
                return "api";
            return "on-device";
        }
    }

    /// Best-effort classify via local OpenAI-compat chat completions. Empty model = miss.
    RoutePlan tryLocalRouterClassify() const
    {
        RoutePlan empty;
        if (!config.routerBaseUrl.length)
            return empty;
        try
        {
            import std.net.curl : HTTP, post;
            import std.uri : encodeComponent;

            JSONValue body = JSONValue.emptyObject;
            body["model"] = JSONValue(config.routerModel);
            JSONValue messages = JSONValue.emptyArray;
            JSONValue sys = JSONValue.emptyObject;
            sys["role"] = JSONValue("system");
            sys["content"] = JSONValue(
                `Reply with JSON only: {"catalogKey":"task-coding|coordinator-voice|discussion-explore|disambiguation-fast|task-architecture"}`);
            messages.array ~= sys;
            JSONValue user = JSONValue.emptyObject;
            user["role"] = JSONValue("user");
            user["content"] = JSONValue("Classify the next harness job.");
            messages.array ~= user;
            body["messages"] = messages;
            body["max_tokens"] = JSONValue(64);

            string url = config.routerBaseUrl;
            if (url.length && url[$ - 1] == '/')
                url = url[0 .. $ - 1];
            if (!canFind(url, "/chat/completions"))
                url ~= "/chat/completions";

            auto http = HTTP();
            http.addRequestHeader("Content-Type", "application/json");
            http.operationTimeout = 2.seconds;
            auto resp = post(url, body.toString(), http);
            auto j = parseJSON(resp);
            string content;
            if ("choices" in j && j["choices"].array.length)
            {
                auto msg = j["choices"].array[0]["message"];
                if ("content" in msg)
                    content = msg["content"].str;
            }
            auto key = extractCatalogKey(content);
            if (!key.length)
                return empty;
            return planFromCatalog(key, "", false);
        }
        catch (Exception e)
        {
            return empty;
        }
    }
}

string extractCatalogKey(string content)
{
    auto c = content.strip;
    try
    {
        auto j = parseJSON(c);
        if ("catalogKey" in j)
            return j["catalogKey"].str;
    }
    catch (Exception)
    {
    }
    foreach (k; [
            "task-architecture", "task-coding", "coordinator-voice",
            "discussion-explore", "disambiguation-fast"
        ])
        if (canFind(c, k))
            return k;
    return "";
}

/// Physical + available RAM in MiB (best effort). Returns a large sentinel if unknown.
int availableRamMb()
{
    import std.process : environment;

    if (auto overrideMb = environment.get("HORNET_AVAIL_RAM_MB", null))
    {
        try
            return overrideMb.to!int;
        catch (Exception)
        {
        }
    }
    version (linux)
    {
        import std.file : readText;
        import std.regex : matchFirst, regex;

        try
        {
            auto mem = readText("/proc/meminfo");
            auto m = matchFirst(mem, regex(`MemAvailable:\s+(\d+)\s+kB`));
            if (!m.empty)
                return m[1].to!int / 1024;
        }
        catch (Exception)
        {
        }
    }
    // Windows / other: env override or assume enough RAM for on-device default.
    return 8192;
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

RouterPlacement parseRouterPlacement(string s)
{
    switch (s)
    {
    case "api": return RouterPlacement.api;
    case "auto": return RouterPlacement.auto_;
    default: return RouterPlacement.onDevice;
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

unittest
{
    Mixr m;
    NodeRecord n;
    n.type = NodeType.task;
    auto plan = m.route(n, "fix tests");
    assert(plan.provider != "anthropic");
    assert(!canFind(plan.model.toLower, "claude"));
    assert(plan.model.length);
    assert(m.isProviderSuppressed("anthropic"));
    assert(!m.isProviderSuppressed("openrouter"));
}
