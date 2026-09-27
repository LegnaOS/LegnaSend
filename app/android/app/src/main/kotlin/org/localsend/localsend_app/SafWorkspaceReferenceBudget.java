package org.localsend.localsend_app;

/** Process-wide retained opaque reference metadata budget, including replacement deltas. */
public final class SafWorkspaceReferenceBudget {
    private final int maxCount;
    private final long maxBytes;
    private int count;
    private long bytes;
    public SafWorkspaceReferenceBudget(int maxCount, long maxBytes) { this.maxCount = maxCount; this.maxBytes = maxBytes; }
    public synchronized boolean replace(int countDelta, long byteDelta) {
        long nextCount = (long) count + countDelta;
        long nextBytes = bytes + byteDelta;
        if (nextCount < 0 || nextBytes < 0) throw new IllegalStateException("Reference budget underflow");
        if (nextCount > maxCount || nextBytes > maxBytes) return false;
        count = (int) nextCount; bytes = nextBytes; return true;
    }
    public synchronized int count() { return count; }
    public synchronized long bytes() { return bytes; }
}
