package org.localsend.localsend_app;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** A cancelled provider call continues owning its slot until the real call returns. */
public final class SafWorkspaceWork {
    public interface Action { void run(Ticket ticket); }
    public static final class Ticket {
        public final String id;
        public final long owner;
        private volatile boolean cancelled;
        private final Runnable cancel;
        Ticket(String id, long owner, Runnable cancel) { this.id = id; this.owner = owner; this.cancel = cancel; }
        public boolean cancelled() { return cancelled; }
        public void cancel() {
            synchronized (this) { if (cancelled) return; cancelled = true; }
            cancel.run();
        }
    }
    private final int limit;
    private final Map<String, Ticket> active = new HashMap<>();
    private final ThreadPoolExecutor executor;
    public SafWorkspaceWork(int limit) {
        this.limit = limit;
        executor = new ThreadPoolExecutor(0, limit, 30, TimeUnit.SECONDS, new SynchronousQueue<>(), runnable -> {
            Thread thread = new Thread(runnable, "LegnaSend-documents"); thread.setDaemon(true); return thread;
        });
    }
    public synchronized boolean submit(String id, long owner, Runnable cancel, Action action) {
        if (active.size() >= limit || active.containsKey(id)) return false;
        Ticket ticket = new Ticket(id, owner, cancel);
        active.put(id, ticket);
        try {
            executor.execute(() -> {
                try { action.run(ticket); }
                finally { synchronized (SafWorkspaceWork.this) { active.remove(id, ticket); } }
            });
            return true;
        } catch (java.util.concurrent.RejectedExecutionException error) { active.remove(id, ticket); return false; }
    }
    public void cancel(String id, long owner) {
        Ticket ticket;
        synchronized (this) { ticket = active.get(id); }
        if (ticket != null && ticket.owner == owner) ticket.cancel();
    }
    public void cancelOwner(long owner) {
        ArrayList<Ticket> tickets;
        synchronized (this) { tickets = new ArrayList<>(active.values()); }
        for (Ticket ticket : tickets) if (ticket.owner == owner) ticket.cancel();
    }
    public synchronized int activeCount() { return active.size(); }
    public void shutdownForTest() { executor.shutdownNow(); }
}
