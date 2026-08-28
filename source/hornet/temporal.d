module hornet.temporal;

import hornet.models;
import hornet.store;

import std.array : split;
import std.algorithm : canFind, max, sort, startsWith;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.string : strip, replace;
import std.file : append, exists, readText;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.range : empty;

struct TemporalEngine
{
    ChatStore store;
    enum fadeHours = 48.0;

    string bookmarksPath() const @safe
    {
        return buildPath(store.timelineDir, "bookmarks.jsonl");
    }

    NodeRecord[] scopeNodes(string viewScope)
    {
        auto all = store.loadAllNodes();
        if (viewScope == "global")
            return all;
        if (viewScope.startsWith("node:"))
        {
            auto rootId = viewScope[5 .. $];
            auto ids = subtreeIds(rootId);
            NodeRecord[] out_;
            foreach (n; all)
                if (canFind(ids, n.id))
                    out_ ~= n;
            return out_;
        }
        return all;
    }

    string[] subtreeIds(string rootId)
    {
        string[] out_ = [rootId];
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (n; store.loadAllNodes())
            {
                if (!canFind(out_, n.id) && n.spawnedBy.length &&
                    canFind(out_, n.spawnedBy))
                {
                    out_ ~= n.id;
                    changed = true;
                }
            }
        }
        return out_;
    }

    JSONValue[] tokenSeries(string viewScope = "global")
    {
        JSONValue[] series;
        foreach (node; scopeNodes(viewScope))
            foreach (line; store.readChat(node.id))
                if ("at" in line)
                {
                    JSONValue pt = JSONValue.emptyObject;
                    pt["at"] = line["at"];
                    pt["tokens"] = ("tokens" in line) ? line["tokens"] : JSONValue(0);
                    pt["node"] = JSONValue(node.id);
                    series ~= pt;
                }
        series.sort!((a, b) => a["at"].str < b["at"].str);
        return series;
    }

    double fadeOpacity(ref const NodeRecord node, SysTime at)
    {
        if (node.awaitingUser || isTerminal(node.status))
            return 1.0;
        if (!node.lastTouchedAt.length)
            return 0.35;
        auto last = parseIso(node.lastTouchedAt);
        if (last == SysTime.init)
            return 0.35;
        auto hours = (at - last).total!"hours";
        if (hours <= 1)
            return 1.0;
        if (hours >= fadeHours)
            return 0.2;
        return max(0.2, 1.0 - (hours / fadeHours) * 0.8);
    }

    void addBookmark(string viewScope, string[] keywords, string text = "", string image = "")
    {
        JSONValue rec = JSONValue.emptyObject;
        rec["scope"] = JSONValue(viewScope);
        rec["at"] = JSONValue(utcNow());
        JSONValue kw = JSONValue.emptyArray;
        foreach (k; keywords)
            kw.array ~= JSONValue(k);
        rec["keywords"] = kw;
        rec["text"] = JSONValue(text);
        if (image.length)
            rec["image"] = JSONValue(image);
        append(bookmarksPath, rec.toString ~ "\n");
        store.appendMetathread("bookmark", rec);
    }

    JSONValue[] loadBookmarks(string viewScope = "global", double zoom = 1.0)
    {
        JSONValue[] lines;
        if (!exists(bookmarksPath))
            return lines;
        foreach (l; readText(bookmarksPath).split('\n'))
            if (l.strip.length)
                lines ~= parseJSON(l);
        JSONValue[] scoped;
        foreach (b; lines)
            if (viewScope == "global" || ("scope" in b && b["scope"].str == viewScope))
                scoped ~= b;
        JSONValue[] out_;
        auto maxKw = cast(int) max(1.0, zoom * 3);
        foreach (b; scoped)
        {
            JSONValue o = b;
            if ("keywords" in b)
            {
                JSONValue nk = JSONValue.emptyArray;
                int i;
                foreach (k; b["keywords"].array)
                {
                    if (i >= maxKw)
                        break;
                    nk.array ~= k;
                    i++;
                }
                o["keywords"] = nk;
            }
            out_ ~= o;
        }
        return out_;
    }

    JSONValue snapshot(string viewScope = "global", string atIso = null, double zoom = 1.0)
    {
        SysTime at = atIso.length ? parseIso(atIso) : Clock.currTime(UTC());
        JSONValue[] visible;
        foreach (n; scopeNodes(viewScope))
        {
            if (n.hidden)
                continue;
            if (n.lastEventAt.length)
            {
                auto last = parseIso(n.lastEventAt);
                if (last != SysTime.init && last > at)
                    continue;
            }
            JSONValue o = n.toJson();
            o["opacity"] = JSONValue(fadeOpacity(n, at));
            visible ~= o;
        }
        JSONValue[] tokens;
        foreach (t; tokenSeries(viewScope))
        {
            auto ts = parseIso(t["at"].str);
            if (ts != SysTime.init && ts <= at)
                tokens ~= t;
        }
        JSONValue root = JSONValue.emptyObject;
        root["scope"] = JSONValue(viewScope);
        root["at"] = JSONValue(at.toISOString());
        root["zoom"] = JSONValue(zoom);
        JSONValue na = JSONValue.emptyArray;
        foreach (v; visible)
            na.array ~= v;
        root["nodes"] = na;
        JSONValue ta = JSONValue.emptyArray;
        foreach (t; tokens)
            ta.array ~= t;
        root["tokenSeries"] = ta;
        JSONValue ba = JSONValue.emptyArray;
        foreach (b; loadBookmarks(viewScope, zoom))
            ba.array ~= b;
        root["bookmarks"] = ba;
        root["heatmap"] = heatmapBuckets(tokens);
        return root;
    }

private:
    SysTime parseIso(string s)
    {
        try
            return SysTime.fromISOString(s.replace("Z", "+00:00"));
        catch (Exception)
            return SysTime.init;
    }

    JSONValue heatmapBuckets(JSONValue[] tokens, int buckets = 24)
    {
        double[] counts = new double[buckets];
        foreach (t; tokens)
        {
            auto dt = parseIso(t["at"].str);
            if (dt == SysTime.init)
                continue;
            counts[dt.hour % buckets] += ("tokens" in t) ? t["tokens"].integer : 0;
        }
        double peak = 1;
        foreach (c; counts)
            peak = max(peak, c);
        JSONValue arr = JSONValue.emptyArray;
        foreach (c; counts)
            arr.array ~= JSONValue(c / peak);
        return arr;
    }
}

private string utcNow()
{
    return Clock.currTime(UTC()).toISOString();
}
