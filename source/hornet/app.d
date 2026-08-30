module hornet.app;

import hornet.rt;
import hornet.mixr;
import hornet.models;
import hornet.server;
import hornet.store;

import std.array : split;
import std.conv : to;
import std.getopt;
import std.json : JSONValue;
import std.stdio;

int main(string[] args)
{
    if (args.length < 2)
    {
        printUsage();
        return 1;
    }
    auto cmd = args[1];
    args = args[1 .. $];

    switch (cmd)
    {
    case "init":
        return cmdInit(args);
    case "spawn":
        return cmdSpawn(args);
    case "message":
        return cmdMessage(args);
    case "status":
        return cmdStatus(args);
    case "graph":
        return cmdGraph(args);
    case "serve":
        return cmdServe(args);
    case "route":
        return cmdRoute(args);
    default:
        printUsage();
        return 1;
    }
}

int cmdInit(string[] args)
{
    string chatRoot;
    string title = "Hornet session";
    getopt(args, "title", &title);
    if (args.length < 2)
        return 1;
    chatRoot = args[1];
    ChatStore store = { root: chatRoot };
    auto coord = store.initSession(title);
    JSONValue o = JSONValue.emptyObject;
    o["root"] = JSONValue(coord.id);
    o["path"] = JSONValue(chatRoot);
    writeln(o.toPrettyString());
    return 0;
}

int cmdSpawn(string[] args)
{
    string chatRoot, parent, type, title, topic, reason;
    bool disambiguation;
    getopt(args, "parent", &parent, "type", &type, "title", &title, "topic", &topic, "reason", &reason,
        "disambiguation", &disambiguation);
    if (args.length < 2 || !parent.length || !type.length)
        return 1;
    chatRoot = args[1];
    ChatStore store = { root: chatRoot };
    auto child = store.spawn(parent, parseNodeType(type), title, topic, reason, disambiguation);
    JSONValue o = JSONValue.emptyObject;
    o["id"] = JSONValue(child.id);
    o["type"] = JSONValue(cast(string) child.type);
    o["address"] = JSONValue(child.address);
    writeln(o.toPrettyString());
    return 0;
}

int cmdMessage(string[] args)
{
    string chatRoot, node, role = "user", text;
    bool proposeSpawn;
    getopt(args, "node", &node, "role", &role, "text", &text, "propose-spawn", &proposeSpawn);
    if (args.length < 2 || !node.length || !text.length)
        return 1;
    chatRoot = args[1];
    ChatStore store = { root: chatRoot };
    auto lineNo = store.appendChat(node, ChatLine(role, text, cast(int) text.split.length));
    if (role == "user" && proposeSpawn)
    {
        NodeRecord spawned;
        if (store.proposeSpawnFromMessage(node, text, spawned))
        {
            JSONValue o = JSONValue.emptyObject;
            o["spawned"] = JSONValue(spawned.id);
            o["line"] = JSONValue(lineNo);
            writeln(o.toPrettyString());
            return 0;
        }
    }
    JSONValue o = JSONValue.emptyObject;
    o["line"] = JSONValue(lineNo);
    writeln(o.toPrettyString());
    return 0;
}

int cmdStatus(string[] args)
{
    string chatRoot, node, status, summary;
    getopt(args, "node", &node, "status", &status, "summary", &summary);
    if (args.length < 2 || !node.length || !status.length)
        return 1;
    chatRoot = args[1];
    ChatStore store = { root: chatRoot };
    auto n = store.setStatus(node, parseNodeStatus(status), summary);
    JSONValue o = JSONValue.emptyObject;
    o["id"] = JSONValue(n.id);
    o["status"] = JSONValue(cast(string) n.status);
    o["summary"] = JSONValue(n.summary);
    writeln(o.toPrettyString());
    return 0;
}

int cmdGraph(string[] args)
{
    if (args.length < 2)
        return 1;
    ChatStore store = { root: args[1] };
    JSONValue arr = JSONValue.emptyArray;
    foreach (n; store.loadAllNodes())
        arr.array ~= n.toJson();
    writeln(arr.toPrettyString());
    return 0;
}

int cmdServe(string[] args)
{
    string chatRoot, host = "127.0.0.1", policy = "balanced";
    uint port = 8765;
    getopt(args, "host", &host, "port", &port, "policy", &policy);
    if (args.length < 2)
        return 1;
    chatRoot = args[1];
    runServer(chatRoot, host, cast(ushort) port, parsePolicy(policy));
    return 0;
}

int cmdRoute(string[] args)
{
    string chatRoot, node, hint, policy = "balanced";
    getopt(args, "node", &node, "hint", &hint, "policy", &policy);
    if (args.length < 2 || !node.length)
        return 1;
    chatRoot = args[1];
    ChatStore store = { root: chatRoot };
    Mixr mixr;
    mixr.policy = parsePolicy(policy);
    auto rec = store.loadNode(node);
    auto plan = mixr.route(rec, hint);
    mixr.applyToNode(rec, plan);
    store.saveNode(rec);
    JSONValue route = JSONValue.emptyObject;
    route["node"] = JSONValue(node);
    foreach (string k, v; plan.toJson().object)
        route[k] = v;
    store.appendMetathread("route", route);
    writeln(plan.toJson().toPrettyString());
    return 0;
}

void printUsage()
{
    writeln(`hornet — DevCentr actor-model harness (D + tgc)

Commands:
  hornet init <chat-root> [--title=...]
  hornet spawn <chat-root> --parent=... --type=task|discussion|disambiguation [--title=...]
  hornet message <chat-root> --node=... --text=... [--propose-spawn]
  hornet status <chat-root> --node=... --status=running|done|...
  hornet graph <chat-root>
  hornet serve <chat-root> [--port=8765] [--policy=balanced]
  hornet route <chat-root> --node=... [--hint=...]
`);
}
