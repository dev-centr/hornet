module hornet_store_test;

import hornet.models : ChatLine, NodeRecord, NodeType;
import hornet.store : ChatStore;

import std.algorithm : canFind;

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.random : uniform;
    import std.conv : to;

    auto tmp = buildPath(tempDir, "hornet-" ~ uniform(100_000, 999_999).to!string);
    mkdirRecurse(tmp);
    scope (exit)
        if (exists(tmp))
            rmdirRecurse(tmp);

    ChatStore store = { root: tmp };
    auto coord = store.initSession("Test");
    assert(coord.id == "coordinator");

    auto task = store.spawn("coordinator", NodeType.task, "docs-sync", "", "multi-repo");
    assert(task.spawnedBy == "coordinator");
    auto parent = store.loadNode("coordinator");
    assert(canFind(parent.spawned, task.id));

    auto line = store.appendChat(task.id, ChatLine("user", "hello", 1));
    assert(line == 1);
    assert(store.readChat(task.id).length == 1);

    NodeRecord spawned;
    assert(store.proposeSpawnFromMessage("coordinator", "Also, we should fix the CLA thing", spawned));
    assert(spawned.type == NodeType.discussion);

    assert(store.proposeSpawnFromMessage("coordinator",
        "Continue the merge or we could also refactor the timeline engine", spawned));
    assert(spawned.type == NodeType.disambiguation);
}
