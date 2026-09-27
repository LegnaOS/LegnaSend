package org.localsend.localsend_app;

/** Deterministic host ownership checks; not provider notification/device evidence. */
public final class SafWorkspaceWatchBudgetTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) {
        SafWorkspaceWatchBudget leases = new SafWorkspaceWatchBudget(3, 2, 30);
        require(leases.reserve("owner-a/workspace/generation-1", "dir-a", 0));
        require(leases.reserve("owner-a/workspace/generation-1", "dir-b", 0));
        require(!leases.reserve("owner-a/workspace/generation-1", "dir-c", 0));
        require(leases.reserve("owner-b/workspace/generation-1", "dir-c", 0));
        require(!leases.reserve("owner-c", "dir-d", 0));
        require(!leases.reserve("owner-b/workspace/generation-1", "dir-a", 1));
        require(leases.reserve("owner-a/workspace/generation-1", "dir-a", 15));
        require(leases.active("dir-a", 30));
        require(!leases.active("dir-b", 30));
        require(leases.expired(30).size() == 2);
        require(!leases.reserve("owner-a/workspace/generation-1", "dir-b", 30));
        require(!leases.reserve("owner-c", "dir-d", 30)); // Expiry alone cannot free a native resource.
        leases.released("dir-b");
        require(leases.reserve("owner-a/workspace/generation-1", "dir-b", 30));
        leases.released("dir-c");
        require(leases.reserve("owner-a/workspace/generation-2", "dir-new", 30));
        require(leases.active("dir-a", 44));
        require(!leases.active("dir-a", 45));
        require(leases.active("dir-b", 45)); // Cleanup of another directory cannot invalidate this lease.
        leases.released("dir-a"); leases.released("dir-b"); leases.released("dir-new");
        require(leases.size() == 0);
        System.out.println("PASS: bounded per-owner/global watches; exact owner/generation; foreground renewal; expiry keeps real resource ownership; independent release");
    }
}
