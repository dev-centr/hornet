module hornet.server;

import hornet.mixr;
import hornet.models;
import hornet.store;
import hornet.temporal;
import hornet.waitgraph;

import std.array : split;
import std.algorithm : endsWith, startsWith;
import std.conv : to;
import std.datetime.timezone;
import std.file : exists, readText, thisExePath;
import std.json : JSONValue, parseJSON;
import std.socket;
import std.stdio : writeln;
import std.path : buildPath, dirName;
import std.string : indexOf, strip;

struct ServerContext
{
    ChatStore store;
    Mixr mixr;
    TemporalEngine temporal;
    string webDir;
}

void runServer(string chatRoot, string host = "127.0.0.1", ushort port = 8765, Policy policy = Policy.balanced)
{
    ServerContext ctx;
    ctx.store.root = chatRoot;
    if (ctx.store.listNodeIds().length == 0)
        ctx.store.initSession("Hornet desk");

    if (ctx.store.loadAllNodes().length <= 1)
    {
        ctx.store.spawn("coordinator", NodeType.task, "docs-sync", "", "demo seed");
        ctx.store.setStatus("docs-sync", NodeStatus.running, "Merge docs#3 onto main");
        ctx.store.spawn("coordinator", NodeType.task, "bitwarden-22642", "", "demo seed");
        ctx.store.setStatus("bitwarden-22642", NodeStatus.running, "Retry bitwarden#22642");
        ctx.store.spawn("coordinator", NodeType.task, "openshellorg-prohelp", "", "demo seed");
        ctx.store.setStatus("openshellorg-prohelp", NodeStatus.blocked, "CLA blocked on org");
    }

    ctx.mixr.policy = policy;
    ctx.temporal.store = ctx.store;
    ctx.webDir = "web";
    if (!exists(buildPath(ctx.webDir, "index.html")))
    {
        import std.file : thisExePath;
        ctx.webDir = buildPath(dirName(thisExePath()), "..", "..", "web");
    }

    auto addr = parseAddress(host, port);
    auto listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    listener.bind(addr);
    listener.listen(10);
    scope (exit)
        listener.close();

    writeln("Hornet desk http://", host, ":", port, "  chat_root=", chatRoot, "  (tgc via Tgc_default)");

    for (;;)
    {
        Socket client = listener.accept();
        scope (exit)
            client.close();
        ubyte[65536] buf;
        auto n = client.receive(buf);
        if (n <= 0)
            continue;
        auto req = cast(string) buf[0 .. n];
        auto resp = handleRequest(ctx, req);
        client.send(cast(ubyte[]) resp);
    }
}

string handleRequest(ref ServerContext ctx, string req)
{
    auto lineEnd = req.indexOf("\r\n");
    if (lineEnd < 0)
        return errorResponse(400, "bad request");
    auto parts = req[0 .. lineEnd].split(' ');
    if (parts.length < 2)
        return errorResponse(400, "bad request");
    auto method = parts[0];
    auto target = parts[1];
    auto qm = target.indexOf('?');
    string path = qm >= 0 ? target[0 .. qm] : target;
    string query = qm >= 0 ? target[qm + 1 .. $] : "";

    string body;
    auto bi = req.indexOf("\r\n\r\n");
    if (bi >= 0 && method == "POST")
        body = req[bi + 4 .. $];

    if (method == "GET")
    {
        if (path == "/" || path == "/index.html")
            return fileResponse(buildPath(ctx.webDir, "index.html"), "text/html");
        if (path.startsWith("/static/"))
            return fileResponse(buildPath(ctx.webDir, path[8 .. $]), mimeFor(path));
        if (path == "/api/graph")
        {
            JSONValue nodes = JSONValue.emptyArray;
            foreach (n; ctx.store.loadAllNodes())
                if (!n.hidden)
                    nodes.array ~= n.toJson();
            JSONValue o = JSONValue.emptyObject;
            o["graph"] = ctx.store.loadGraph().toJson();
            o["nodes"] = nodes;
            return jsonResponse(200, o);
        }
        if (path == "/api/metathread")
        {
            JSONValue o = JSONValue.emptyObject;
            JSONValue la = JSONValue.emptyArray;
            foreach (l; ctx.store.readMetathread(50))
                la.array ~= l;
            o["lines"] = la;
            return jsonResponse(200, o);
        }
        if (path.startsWith("/api/nodes/") && path.endsWith("/chat"))
        {
            auto segs = path.split('/');
            if (segs.length >= 4)
            {
                JSONValue o = JSONValue.emptyObject;
                JSONValue la = JSONValue.emptyArray;
                foreach (l; ctx.store.readChat(segs[3], 100))
                    la.array ~= l;
                o["lines"] = la;
                return jsonResponse(200, o);
            }
        }
        if (path == "/api/temporal")
        {
            string viewScope = queryParam(query, "scope", "global");
            string at = queryParam(query, "at", "");
            double zoom = queryParam(query, "zoom", "1").to!double;
            return jsonResponse(200, ctx.temporal.snapshot(viewScope, at, zoom));
        }
        if (path == "/api/health" || path == "/health")
        {
            JSONValue o = JSONValue.emptyObject;
            o["ok"] = JSONValue(true);
            o["name"] = JSONValue("hornet");
            o["version"] = JSONValue("0.5.0");
            o["mixr"] = ctx.mixr.statusJson();
            return jsonResponse(200, o);
        }
        if (path == "/v1/models")
        {
            JSONValue data = JSONValue.emptyArray;
            foreach (id; [
                    "z-ai/glm-5.3-flash", "z-ai/glm-5.3", "minimax/minimax-m3",
                    "moonshotai/kimi-k3", "deepseek/deepseek-chat", "mixr-router"
                ])
            {
                JSONValue m = JSONValue.emptyObject;
                m["id"] = JSONValue(id);
                m["object"] = JSONValue("model");
                data.array ~= m;
            }
            JSONValue o = JSONValue.emptyObject;
            o["object"] = JSONValue("list");
            o["data"] = data;
            return jsonResponse(200, o);
        }
    }
    else if (method == "POST")
    {
        auto j = body.length ? parseJSON(body) : JSONValue.emptyObject;
        if (path == "/api/message")
        {
            auto nodeId = j["nodeId"].str;
            auto text = j["text"].str;
            auto role = ("role" in j) ? j["role"].str : "user";
            auto lineNo = ctx.store.appendChat(nodeId, ChatLine(role, text, cast(int) text.split.length));
            JSONValue o = JSONValue.emptyObject;
            o["line"] = JSONValue(lineNo);
            if (role == "user")
            {
                NodeRecord spawned;
                if (ctx.store.proposeSpawnFromMessage(nodeId, text, spawned))
                    o["spawned"] = spawned.toJson();
            }
            return jsonResponse(200, o);
        }
        if (path == "/api/spawn")
        {
            auto child = ctx.store.spawn(j["parentId"].str, parseNodeType(j["type"].str),
                ("title" in j) ? j["title"].str : "", ("topic" in j) ? j["topic"].str : "",
                ("reason" in j) ? j["reason"].str : "",
                ("disambiguation" in j) && j["disambiguation"].boolean);
            auto plan = ctx.mixr.route(child, ("title" in j) ? j["title"].str : "");
            ctx.mixr.applyToNode(child, plan);
            ctx.store.saveNode(child);
            JSONValue route = JSONValue.emptyObject;
            route["node"] = JSONValue(child.id);
            foreach (string k, v; plan.toJson().object)
                route[k] = v;
            ctx.store.appendMetathread("route", route);
            JSONValue o = JSONValue.emptyObject;
            o["node"] = child.toJson();
            o["route"] = plan.toJson();
            return jsonResponse(200, o);
        }
        if (path == "/api/status")
        {
            auto node = ctx.store.setStatus(j["nodeId"].str, parseNodeStatus(j["status"].str),
                ("summary" in j) ? j["summary"].str : "");
            JSONValue o = JSONValue.emptyObject;
            o["node"] = node.toJson();
            return jsonResponse(200, o);
        }
        if (path == "/api/hide")
        {
            const bool hidden = ("hidden" in j) ? j["hidden"].boolean : true;
            auto node = ctx.store.hideNode(j["nodeId"].str, hidden);
            JSONValue o = JSONValue.emptyObject;
            o["node"] = node.toJson();
            return jsonResponse(200, o);
        }
        if (path == "/api/route")
        {
            auto node = ctx.store.loadNode(j["nodeId"].str);
            auto plan = ctx.mixr.route(node, ("hint" in j) ? j["hint"].str : "");
            ctx.mixr.applyToNode(node, plan);
            ctx.store.saveNode(node);
            JSONValue route = JSONValue.emptyObject;
            route["node"] = JSONValue(node.id);
            foreach (string k, v; plan.toJson().object)
                route[k] = v;
            ctx.store.appendMetathread("route", route);
            WaitCheck[] checks;
            WaitGraph wg = { store: ctx.store };
            auto ok = wg.canProceed(node, checks);
            JSONValue o = JSONValue.emptyObject;
            o["route"] = plan.toJson();
            o["waitGraphOk"] = JSONValue(ok);
            JSONValue ca = JSONValue.emptyArray;
            foreach (c; checks)
            {
                JSONValue co = JSONValue.emptyObject;
                co["nodeId"] = JSONValue(c.nodeId);
                co["mode"] = JSONValue(cast(string) c.mode);
                co["ok"] = JSONValue(c.ok);
                co["status"] = JSONValue(c.status);
                co["message"] = JSONValue(c.message);
                ca.array ~= co;
            }
            o["waitChecks"] = ca;
            return jsonResponse(200, o);
        }
        if (path == "/api/bookmark")
        {
            string[] kw;
            if ("keywords" in j)
                foreach (k; j["keywords"].array)
                    kw ~= k.str;
            ctx.temporal.addBookmark(("scope" in j) ? j["scope"].str : "global", kw,
                ("text" in j) ? j["text"].str : "", ("image" in j) ? j["image"].str : "");
            JSONValue o = JSONValue.emptyObject;
            o["ok"] = JSONValue(true);
            return jsonResponse(200, o);
        }
        if (path == "/api/provider/session")
        {
            // t3code HornetDriver: map a remote thread to a discussion node under coordinator.
            auto threadId = ("threadId" in j) ? j["threadId"].str : "";
            auto title = ("title" in j) ? j["title"].str : "t3-thread";
            if (!title.length)
                title = "t3-thread";
            string nodeId = ("resumeNodeId" in j) ? j["resumeNodeId"].str : "";
            NodeRecord node;
            if (nodeId.length)
            {
                try
                    node = ctx.store.loadNode(nodeId);
                catch (Exception)
                    nodeId = "";
            }
            if (!nodeId.length)
            {
                node = ctx.store.spawn("coordinator", NodeType.discussion, title,
                    threadId, "t3code provider session");
                auto plan = ctx.mixr.route(node, title);
                ctx.mixr.applyToNode(node, plan);
                ctx.store.saveNode(node);
            }
            JSONValue o = JSONValue.emptyObject;
            o["sessionId"] = JSONValue(node.id);
            o["nodeId"] = JSONValue(node.id);
            o["threadId"] = JSONValue(threadId);
            o["title"] = JSONValue(node.title.length ? node.title : title);
            o["mixrModel"] = JSONValue(node.mixrModel);
            o["mixrReason"] = JSONValue(node.mixrReason);
            return jsonResponse(200, o);
        }
        if (path == "/api/provider/turn")
        {
            auto nodeId = j["sessionId"].str;
            auto text = ("input" in j) ? j["input"].str : "";
            const allowSuppressed = ("allowSuppressed" in j) && j["allowSuppressed"].boolean;
            ctx.store.appendChat(nodeId, ChatLine("user", text, cast(int) text.split.length));
            auto node = ctx.store.loadNode(nodeId);
            auto plan = ctx.mixr.route(node, text, allowSuppressed);
            ctx.mixr.applyToNode(node, plan);
            ctx.store.saveNode(node);
            ctx.store.setStatus(nodeId, NodeStatus.running, "t3 turn");

            // Stub assistant until Hornet wires live provider completions.
            // Persists route metadata so t3code can stream a useful reply.
            import std.format : format;
            auto assistant = format(
                "Mixr route → **%s** via `%s` (%s).\n\n%s\n\n_Hornet received your turn and persisted it on node `%s`. Live model invoke is next; this reply confirms the provider seam._",
                plan.model, plan.provider, plan.catalogKey, plan.reason, nodeId);
            ctx.store.appendChat(nodeId, ChatLine("assistant", assistant, cast(int) assistant.split.length));
            ctx.store.setStatus(nodeId, NodeStatus.idle, "awaiting next turn");

            JSONValue o = JSONValue.emptyObject;
            o["sessionId"] = JSONValue(nodeId);
            o["assistantText"] = JSONValue(assistant);
            o["route"] = plan.toJson();
            return jsonResponse(200, o);
        }
        if (path == "/v1/chat/completions")
        {
            // OpenAI-compat stub: returns Mixr route plan as assistant content.
            string hint;
            if ("messages" in j)
                foreach (m; j["messages"].array)
                    if (("role" in m) && m["role"].str == "user" && ("content" in m))
                        hint = m["content"].str;
            NodeRecord phantom;
            phantom.type = NodeType.task;
            phantom.id = "openai-compat";
            const allowSuppressed = ("allow_suppressed" in j) && j["allow_suppressed"].boolean;
            auto plan = ctx.mixr.route(phantom, hint, allowSuppressed);
            JSONValue message = JSONValue.emptyObject;
            message["role"] = JSONValue("assistant");
            message["content"] = JSONValue(plan.toJson().toString());
            JSONValue choice = JSONValue.emptyObject;
            choice["index"] = JSONValue(0);
            choice["message"] = message;
            choice["finish_reason"] = JSONValue("stop");
            JSONValue o = JSONValue.emptyObject;
            o["id"] = JSONValue("hornet-mixr");
            o["object"] = JSONValue("chat.completion");
            o["model"] = JSONValue(("model" in j) ? j["model"].str : plan.model);
            JSONValue choices = JSONValue.emptyArray;
            choices.array ~= choice;
            o["choices"] = choices;
            o["route"] = plan.toJson();
            return jsonResponse(200, o);
        }
    }
    return jsonResponse(404, JSONValue(["error": JSONValue("not found")]));
}

private string queryParam(string query, string key, string defaultVal)
{
    foreach (part; query.split('&'))
    {
        auto eq = part.indexOf('=');
        if (eq < 0)
            continue;
        if (part[0 .. eq] == key)
            return part[eq + 1 .. $];
    }
    return defaultVal;
}

private string jsonResponse(int code, JSONValue payload)
{
    auto body = payload.toString();
    return formatResponse(code, "application/json; charset=utf-8", body);
}

private string errorResponse(int code, string msg)
{
    return jsonResponse(code, JSONValue(["error": JSONValue(msg)]));
}

private string fileResponse(string path, string ctype)
{
    if (!exists(path))
        return jsonResponse(404, JSONValue(["error": JSONValue("missing file")]));
    return formatResponse(200, ctype, readText(path));
}

private string formatResponse(int code, string ctype, string body)
{
    import std.format : format;
    string status = code == 200 ? "OK" : (code == 404 ? "Not Found" : "Error");
    return format("HTTP/1.1 %s %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s",
        code, status, ctype, body.length, body);
}

private string mimeFor(string path)
{
    if (path.endsWith(".css"))
        return "text/css";
    if (path.endsWith(".js"))
        return "application/javascript";
    if (path.endsWith(".html"))
        return "text/html";
    return "application/octet-stream";
}
