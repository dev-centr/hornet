module hornet.waitgraph;

import hornet.models;
import hornet.store;

struct WaitCheck
{
    string nodeId;
    WaitMode mode;
    bool ok;
    string status;
    string message;
}

struct WaitGraph
{
    ChatStore store;
    WaitMode defaultMode = WaitMode.warn;

    WaitCheck[] check(ref const NodeRecord node)
    {
        WaitCheck[] results;
        foreach (sub; node.waitOn)
        {
            WaitMode mode = sub.mode;
            NodeRecord sibling;
            try
                sibling = store.loadNode(sub.node);
            catch (Exception e)
            {
                results ~= WaitCheck(sub.node, mode, false, "missing", "Unknown node " ~ sub.node);
                continue;
            }
            if (isTerminal(sibling.status))
            {
                results ~= WaitCheck(sub.node, mode, true, cast(string) sibling.status,
                    "Terminal — safe to read");
            }
            else if (mode == WaitMode.warn)
            {
                results ~= WaitCheck(sub.node, mode, true, cast(string) sibling.status,
                    "WARN: mailbox may be stale (" ~ cast(string) sibling.status ~ ")");
            }
            else
            {
                results ~= WaitCheck(sub.node, mode, false, cast(string) sibling.status,
                    "ENFORCE: blocked until terminal (now " ~ cast(string) sibling.status ~ ")");
            }
        }
        return results;
    }

    bool canProceed(ref const NodeRecord node, out WaitCheck[] checks)
    {
        checks = check(node);
        foreach (c; checks)
            if (!c.ok)
                return false;
        return true;
    }
}
