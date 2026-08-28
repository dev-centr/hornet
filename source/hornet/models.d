module hornet.models;

import std.json : JSONValue;

enum NodeType : string
{
    coordinator = "coordinator",
    discussion = "discussion",
    task = "task",
    disambiguation = "disambiguation",
}

enum NodeStatus : string
{
    idle = "idle",
    running = "running",
    blocked = "blocked",
    done = "done",
    failed = "failed",
    awaitingUser = "awaiting_user",
}

enum WaitMode : string
{
    warn = "warn",
    enforce = "enforce",
}

struct WaitOn
{
    string node;
    WaitMode mode = WaitMode.warn;
}

struct ChatLine
{
    string role;
    string text;
    int tokens;
}

struct NodeRecord
{
    string id;
    NodeType type;
    string address;
    NodeStatus status = NodeStatus.idle;
    string summary;
    string spawnedBy;
    string[] spawned;
    bool awaitingUser;
    bool hidden;
    string title;
    string topic;
    string mixrModel;
    string mixrReason;
    string lastEventAt;
    string lastTouchedAt;
    string createdAt;
    WaitOn[] waitOn;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["id"] = JSONValue(id);
        o["type"] = JSONValue(cast(string) type);
        o["address"] = JSONValue(address);
        o["status"] = JSONValue(cast(string) status);
        o["summary"] = JSONValue(summary);
        if (spawnedBy.length)
            o["spawnedBy"] = JSONValue(spawnedBy);
        JSONValue sp = JSONValue.emptyArray;
        foreach (s; spawned)
            sp.array ~= JSONValue(s);
        o["spawned"] = sp;
        o["awaitingUser"] = JSONValue(awaitingUser);
        o["hidden"] = JSONValue(hidden);
        o["title"] = JSONValue(title);
        o["topic"] = JSONValue(topic);
        if (mixrModel.length)
            o["mixrModel"] = JSONValue(mixrModel);
        if (mixrReason.length)
            o["mixrReason"] = JSONValue(mixrReason);
        if (lastEventAt.length)
            o["lastEventAt"] = JSONValue(lastEventAt);
        if (lastTouchedAt.length)
            o["lastTouchedAt"] = JSONValue(lastTouchedAt);
        if (createdAt.length)
            o["createdAt"] = JSONValue(createdAt);
        if (waitOn.length)
        {
            JSONValue wa = JSONValue.emptyArray;
            foreach (w; waitOn)
            {
                JSONValue wo = JSONValue.emptyObject;
                wo["node"] = JSONValue(w.node);
                wo["mode"] = JSONValue(cast(string) w.mode);
                wa.array ~= wo;
            }
            o["waitOn"] = wa;
        }
        return o;
    }

    static NodeRecord fromJson(JSONValue j)
    {
        NodeRecord n;
        n.id = j["id"].str;
        n.type = cast(NodeType) j["type"].str;
        n.address = j["address"].str;
        if ("status" in j)
            n.status = cast(NodeStatus) j["status"].str;
        if ("summary" in j)
            n.summary = j["summary"].str;
        if ("spawnedBy" in j)
            n.spawnedBy = j["spawnedBy"].str;
        if ("spawned" in j)
            foreach (s; j["spawned"].array)
                n.spawned ~= s.str;
        if ("awaitingUser" in j)
            n.awaitingUser = j["awaitingUser"].boolean;
        if ("hidden" in j)
            n.hidden = j["hidden"].boolean;
        if ("title" in j)
            n.title = j["title"].str;
        if ("topic" in j)
            n.topic = j["topic"].str;
        if ("mixrModel" in j)
            n.mixrModel = j["mixrModel"].str;
        if ("mixrReason" in j)
            n.mixrReason = j["mixrReason"].str;
        if ("lastEventAt" in j)
            n.lastEventAt = j["lastEventAt"].str;
        if ("lastTouchedAt" in j)
            n.lastTouchedAt = j["lastTouchedAt"].str;
        if ("createdAt" in j)
            n.createdAt = j["createdAt"].str;
        if ("waitOn" in j)
            foreach (w; j["waitOn"].array)
                n.waitOn ~= WaitOn(w["node"].str, cast(WaitMode) w["mode"].str);
        return n;
    }
}

struct GraphIndex
{
    int version_ = 1;
    string root = "coordinator";
    JSONValue nodes = JSONValue.emptyObject;

    JSONValue toJson() const
    {
        JSONValue o = JSONValue.emptyObject;
        o["version"] = JSONValue(version_);
        o["root"] = JSONValue(root);
        o["nodes"] = nodes;
        return o;
    }

    static GraphIndex fromJson(JSONValue j)
    {
        GraphIndex g;
        if ("version" in j)
            g.version_ = cast(int) j["version"].integer;
        if ("root" in j)
            g.root = j["root"].str;
        if ("nodes" in j)
            g.nodes = j["nodes"];
        return g;
    }
}

bool isTerminal(NodeStatus s)
{
    return s == NodeStatus.done || s == NodeStatus.failed;
}
