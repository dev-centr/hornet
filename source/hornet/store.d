module hornet.store;

import hornet.models;

import std.array : split;
import std.algorithm : canFind, sort, splitter;
import std.array : appender, replace;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import std.file : append, dirEntries, exists, mkdirRecurse, readText, SpanMode, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.range : empty;
import std.string : strip, toLower;

string utcNow()
{
    return Clock.currTime(UTC()).toISOString();
}

string slugify(string text)
{
    import std.ascii : isAlphaNum;
    string s;
    bool lastDash;
    foreach (c; text.toLower)
    {
        if (isAlphaNum(cast(char) c))
        {
            s ~= c;
            lastDash = false;
        }
        else if (!lastDash && s.length)
        {
            s ~= '-';
            lastDash = true;
        }
    }
    if (s.length && s[$ - 1] == '-')
        s = s[0 .. $ - 1];
    if (s.length > 48)
        s = s[0 .. 48];
    return s.length ? s : "node";
}

struct ChatStore
{
    string root;

    string nodesDir() const @safe { return buildPath(root, "nodes"); }
    string orchDir() const @safe { return buildPath(root, "orchestrator"); }
    string viewsDir() const @safe { return buildPath(root, "views"); }
    string timelineDir() const @safe { return buildPath(root, "timeline"); }
    string graphPath() const @safe { return buildPath(root, "graph.json"); }
    string metaPath() const @safe { return buildPath(orchDir, "meta.jsonl"); }

    void ensureLayout()
    {
        foreach (d; [nodesDir, orchDir, viewsDir, timelineDir])
            mkdirRecurse(d);
        if (!exists(metaPath))
            write(metaPath, "");
    }

    GraphIndex loadGraph()
    {
        if (!exists(graphPath))
            return GraphIndex.init;
        return GraphIndex.fromJson(parseJSON(readText(graphPath)));
    }

    void saveGraph(GraphIndex g)
    {
        write(graphPath, g.toJson().toPrettyString() ~ "\n");
    }

    string nodeDir(string nodeId) const @safe
    {
        return buildPath(nodesDir, nodeId);
    }

    NodeRecord loadNode(string nodeId)
    {
        auto path = buildPath(nodeDir(nodeId), "meta.json");
        enforce(exists(path), "unknown node: " ~ nodeId);
        return NodeRecord.fromJson(parseJSON(readText(path)));
    }

    void saveNode(ref NodeRecord node)
    {
        auto nd = nodeDir(node.id);
        mkdirRecurse(nd);
        write(buildPath(nd, "meta.json"), node.toJson().toPrettyString() ~ "\n");
    }

    string[] listNodeIds()
    {
        string[] ids;
        if (!exists(nodesDir))
            return ids;
        foreach (e; dirEntries(nodesDir, SpanMode.shallow))
            if (e.isDir)
                ids ~= e.name;
        sort(ids);
        return ids;
    }

    NodeRecord[] loadAllNodes()
    {
        NodeRecord[] nodes;
        foreach (id; listNodeIds())
            nodes ~= loadNode(id);
        return nodes;
    }

    size_t appendChat(string nodeId, ChatLine line)
    {
        auto nd = nodeDir(nodeId);
        mkdirRecurse(nd);
        auto chatPath = buildPath(nd, "chat.jsonl");
        size_t existing = 0;
        if (exists(chatPath))
        {
            foreach (l; readText(chatPath).splitter('\n'))
                if (l.strip.length)
                    existing++;
        }
        auto at = utcNow();
        JSONValue rec = JSONValue.emptyObject;
        rec["role"] = JSONValue(line.role);
        rec["text"] = JSONValue(line.text);
        rec["tokens"] = JSONValue(line.tokens);
        rec["at"] = JSONValue(at);
        append(chatPath, rec.toString() ~ "\n");
        auto node = loadNode(nodeId);
        node.lastEventAt = at;
        node.lastTouchedAt = at;
        saveNode(node);
        return existing + 1;
    }

    JSONValue[] readChat(string nodeId, ptrdiff_t limit = -1)
    {
        JSONValue[] lines;
        auto chatPath = buildPath(nodeDir(nodeId), "chat.jsonl");
        if (!exists(chatPath))
            return lines;
        foreach (l; readText(chatPath).splitter('\n'))
            if (l.strip.length)
                lines ~= parseJSON(l);
        if (limit >= 0 && lines.length > cast(size_t) limit)
            lines = lines[$ - cast(size_t) limit .. $];
        return lines;
    }

    void appendMetathread(string kind, JSONValue payload)
    {
        JSONValue rec = JSONValue.emptyObject;
        rec["kind"] = JSONValue(kind);
        rec["at"] = JSONValue(utcNow());
        foreach (string k, v; payload.object)
            rec[k] = v;
        append(metaPath, rec.toString() ~ "\n");
    }

    JSONValue[] readMetathread(ptrdiff_t limit = -1)
    {
        JSONValue[] lines;
        if (!exists(metaPath))
            return lines;
        foreach (l; readText(metaPath).splitter('\n'))
            if (l.strip.length)
                lines ~= parseJSON(l);
        if (limit >= 0 && lines.length > cast(size_t) limit)
            lines = lines[$ - cast(size_t) limit .. $];
        return lines;
    }

    NodeRecord initSession(string title = "Session")
    {
        ensureLayout();
        auto graph = loadGraph();
        if (!listNodeIds().empty)
            return loadNode(graph.root);

        auto now = utcNow();
        NodeRecord coord;
        coord.id = "coordinator";
        coord.type = NodeType.coordinator;
        coord.address = nodeDir("coordinator");
        coord.status = NodeStatus.running;
        coord.title = title;
        coord.topic = title;
        coord.summary = "Coordinator for " ~ title;
        coord.createdAt = now;
        coord.lastEventAt = now;
        coord.lastTouchedAt = now;
        saveNode(coord);
        graph.root = coord.id;
        graph.nodes = JSONValue.emptyObject;
        graph.nodes.object[coord.id] = JSONValue(["type": JSONValue(cast(string) coord.type)]);
        saveGraph(graph);
        JSONValue sum = JSONValue.emptyObject;
        sum["text"] = JSONValue("Hornet session started: " ~ title);
        appendMetathread("summary", sum);
        appendChat(coord.id, ChatLine("assistant", "Coordinator online — " ~ title, 12));
        return coord;
    }

    string uniqueId(string base)
    {
        auto graph = loadGraph();
        string candidate = base;
        int n = 2;
        while (candidate in graph.nodes.object)
        {
            candidate = format("%s-%s", base, n);
            n++;
        }
        return candidate;
    }

    NodeRecord spawn(string parentId, NodeType nodeType, string title = "", string topic = "",
        string reason = "", bool disambiguation = false)
    {
        auto parent = loadNode(parentId);
        auto now = utcNow();
        string base = slugify(title.length ? title : (topic.length ? topic : cast(string) nodeType));
        if (disambiguation)
            base = "disambig-" ~ base;
        string nodeId = uniqueId(base);

        NodeRecord child;
        child.id = nodeId;
        child.type = disambiguation ? NodeType.disambiguation : nodeType;
        child.address = nodeDir(nodeId);
        child.spawnedBy = parentId;
        child.status = NodeStatus.idle;
        child.title = title.length ? title : nodeId;
        child.topic = topic.length ? topic : (title.length ? title : nodeId);
        child.summary = reason.length ? reason : ("Spawned from " ~ parentId);
        child.createdAt = now;
        child.lastEventAt = now;
        child.lastTouchedAt = now;
        saveNode(child);

        parent.spawned ~= nodeId;
        parent.lastEventAt = now;
        saveNode(parent);

        auto graph = loadGraph();
        graph.nodes.object[nodeId] = JSONValue([
            "type": JSONValue(cast(string) child.type),
            "spawnedBy": JSONValue(parentId),
        ]);
        saveGraph(graph);

        string marker = format("→ spawned %s `%s`", cast(string) child.type, nodeId);
        if (reason.length)
            marker ~= ": " ~ reason;
        auto lineNo = appendChat(parentId, ChatLine("routing", marker, 0));
        JSONValue sp = JSONValue.emptyObject;
        sp["parent"] = JSONValue(parentId);
        sp["child"] = JSONValue(nodeId);
        sp["type"] = JSONValue(cast(string) child.type);
        sp["parentLine"] = JSONValue(lineNo);
        sp["reason"] = JSONValue(reason);
        appendMetathread("spawn", sp);
        return child;
    }

    NodeRecord setStatus(string nodeId, NodeStatus status, string summary = "")
    {
        auto node = loadNode(nodeId);
        node.status = status;
        if (summary.length)
            node.summary = summary;
        node.lastEventAt = utcNow();
        saveNode(node);
        JSONValue m = JSONValue.emptyObject;
        m["node"] = JSONValue(nodeId);
        m["status"] = JSONValue(cast(string) status);
        m["summary"] = JSONValue(node.summary);
        appendMetathread("summary", m);
        return node;
    }

    NodeRecord hideNode(string nodeId, bool hidden = true)
    {
        auto node = loadNode(nodeId);
        node.hidden = hidden;
        saveNode(node);
        return node;
    }

    bool proposeSpawnFromMessage(string nodeId, string userText, out NodeRecord spawned)
    {
        string lower = userText.toLower;
        string[] markers = [" also ", "also,", "another idea", "separately", "side note", "new topic",
            "while we're at it"];
        bool hit;
        foreach (m; markers)
            if (canFind(lower, m))
                hit = true;
        if (!hit)
            return false;

        if (canFind(lower, " or ") && (canFind(lower, "continue") || canFind(lower, "either")))
        {
            spawned = spawn(nodeId, NodeType.disambiguation, "boundary",
                userText.length > 120 ? userText[0 .. 120] : userText,
                "Mixed continuation + new ideas", true);
            return true;
        }

        spawned = spawn(nodeId, NodeType.discussion,
            userText.length > 40 ? userText[0 .. 40] : userText,
            userText.length > 200 ? userText[0 .. 200] : userText,
            "Model-proposed spawn on drift");
        return true;
    }
}
