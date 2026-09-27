package org.localsend.localsend_app;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.locks.ReentrantLock;

/** Shared creation leases: cancelling one upload cannot remove its sibling's parent. */
final class SafWorkspaceWriteDirectories {
    interface Backend {
        SafDirectoryResolver.Document find(String parent, String name) throws IOException;
        Set<String> children(String parent) throws IOException;
        String create(String parent, String name) throws IOException;
        SafDirectoryResolver.Document stat(String uri) throws IOException;
        boolean deleteEmpty(String parent, String uri, String name) throws IOException;
    }
    interface Journal { void created(String parent, String name, String uri, boolean proven) throws IOException; }
    interface Check { void active() throws IOException; }
    static final class Owned {
        final String parent, name, uri;
        int users;
        boolean committed;
        Owned(String parent, String name, String uri) { this.parent = parent; this.name = name; this.uri = uri; }
    }
    static final class Lease {
        final List<Owned> directories = new ArrayList<>();
        boolean released;
    }
    private static final class EntryLock { final ReentrantLock lock = new ReentrantLock(); int users; }
    private final Map<String, EntryLock> locks = new HashMap<>();
    private final Map<String, Owned> owned = new HashMap<>();
    private EntryLock acquire(String key) {
        EntryLock value;
        synchronized (this) { value = locks.computeIfAbsent(key, ignored -> new EntryLock()); value.users++; }
        value.lock.lock(); return value;
    }
    private void release(String key, EntryLock value) {
        value.lock.unlock();
        synchronized (this) { if (--value.users == 0) locks.remove(key, value); }
    }
    String resolve(Backend backend, String parent, List<String> components, Lease lease, Check check, Journal journal) throws IOException {
        return resolve(backend,parent,components,lease,check,journal,false);
    }
    String resolve(Backend backend, String parent, List<String> components, Lease lease, Check check, Journal journal, boolean rejectExistingLast) throws IOException {
        int componentIndex = 0;
        for (String name : components) {
            check.active();
            String key = parent + "\n" + name;
            EntryLock lock = acquire(key);
            try {
                check.active();
                SafDirectoryResolver.Document child = backend.find(parent, name);
                if (child != null && rejectExistingLast && componentIndex == components.size()-1) throw new IOException("conflict");
                if (child == null) {
                    Set<String> before = backend.children(parent);
                    check.active();
                    journal.created(parent, name, null, false); // Intent precedes mutation.
                    String uri = backend.create(parent, name);
                    journal.created(parent, name, uri, false); // Unknown results are accounted for.
                    child = uri == null ? null : backend.stat(uri);
                    SafDirectoryResolver.Document located = backend.find(parent, name);
                    boolean proven = child != null && child.directory && name.equals(child.name)
                        && !before.contains(uri) && located != null && uri.equals(located.uri);
                    if (!proven) throw new IOException("publication_unconfirmed");
                    journal.created(parent, name, uri, true);
                    synchronized (this) { owned.put(uri, new Owned(parent, name, uri)); }
                }
                if (!child.directory || !child.canCreate || !name.equals(child.name)) throw new IOException("conflict");
                synchronized (this) {
                    Owned entry = owned.get(child.uri);
                    if (entry != null) { entry.users++; lease.directories.add(entry); }
                }
                check.active();
                parent = child.uri;
                componentIndex++;
            } finally { release(key, lock); }
        }
        return parent;
    }
    void finish(Backend backend, Lease lease, boolean published) {
        synchronized (lease) { if (lease.released) return; lease.released = true; }
        for (int i = lease.directories.size() - 1; i >= 0; i--) {
            Owned entry = lease.directories.get(i);
            String key = entry.parent + "\n" + entry.name;
            EntryLock lock = acquire(key);
            try {
                boolean clean;
                synchronized (this) {
                    entry.committed |= published;
                    clean = --entry.users == 0;
                    if (clean) owned.remove(entry.uri, entry);
                }
                if (clean && !entry.committed) {
                    // Failure is retained in the durable creation journal. Never
                    // recursively remove a provider directory or foreign child.
                    try { backend.deleteEmpty(entry.parent, entry.uri, entry.name); } catch (IOException | RuntimeException ignored) {}
                }
            } finally { release(key, lock); }
        }
    }
}
