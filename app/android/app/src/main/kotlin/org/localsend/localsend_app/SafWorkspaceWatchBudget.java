package org.localsend.localsend_app;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Bounded foreground-directory observation leases; expiry is monotonic time. */
final class SafWorkspaceWatchBudget {
    private static final class Lease {
        final String scope;
        long expires;
        Lease(String scope, long expires) { this.scope = scope; this.expires = expires; }
    }
    private final int globalLimit, scopeLimit;
    private final long ttl;
    private final Map<String, Lease> leases = new HashMap<>();
    SafWorkspaceWatchBudget(int globalLimit, int scopeLimit, long ttl) {
        if (globalLimit < 1 || scopeLimit < 1 || ttl < 1) throw new IllegalArgumentException();
        this.globalLimit = globalLimit; this.scopeLimit = scopeLimit; this.ttl = ttl;
    }
    synchronized boolean reserve(String scope, String key, long now) {
        Lease existing = leases.get(key);
        if (existing != null) {
            if (!existing.scope.equals(scope) || existing.expires <= now) return false;
            existing.expires = saturatingAdd(now, ttl); return true;
        }
        if (leases.size() >= globalLimit) return false;
        int count = 0;
        for (Lease lease : leases.values()) if (lease.scope.equals(scope)) count++;
        if (count >= scopeLimit) return false;
        leases.put(key, new Lease(scope, saturatingAdd(now, ttl))); return true;
    }
    synchronized boolean active(String key, long now) {
        Lease lease = leases.get(key); return lease != null && lease.expires > now;
    }
    synchronized List<String> expired(long now) {
        List<String> result = new ArrayList<>();
        for (Map.Entry<String, Lease> entry : leases.entrySet()) if (entry.getValue().expires <= now) result.add(entry.getKey());
        return result;
    }
    // Release only after the corresponding native observer really unregisters.
    synchronized void released(String key) { leases.remove(key); }
    synchronized int size() { return leases.size(); }
    private static long saturatingAdd(long value, long delta) {
        return value > Long.MAX_VALUE - delta ? Long.MAX_VALUE : value + delta;
    }
}
