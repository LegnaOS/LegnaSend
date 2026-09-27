package org.localsend.localsend_app;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Bounded round-robin metadata probes of entries already returned by a list. */
final class SafWorkspaceEntryHints<T> {
    static final class Probe<T> {
        final String id;
        final T value;
        Probe(String id, T value) { this.id = id; this.value = value; }
    }
    private final int capacity;
    private final LinkedHashMap<String, Probe<T>> entries = new LinkedHashMap<>();

    SafWorkspaceEntryHints(int capacity) {
        if (capacity < 1) throw new IllegalArgumentException("capacity");
        this.capacity = capacity;
    }

    synchronized void listed(String id, T value) {
        Objects.requireNonNull(value);
        entries.remove(id);
        entries.put(id, new Probe<>(id, value));
        while (entries.size() > capacity) entries.remove(entries.keySet().iterator().next());
    }

    synchronized List<Probe<T>> next(int limit) {
        List<Probe<T>> result = new ArrayList<>();
        if (limit < 1) return result;
        for (Map.Entry<String, Probe<T>> entry : entries.entrySet()) {
            result.add(entry.getValue());
            if (result.size() == limit) break;
        }
        for (Probe<T> probe : result) {
            entries.remove(probe.id);
            entries.put(probe.id, probe);
        }
        return result;
    }

    // A late query must not replace a newer listing or another query result.
    // Null means a confirmed missing document, not an unavailable provider.
    synchronized boolean observed(Probe<T> probe, T current) {
        if (entries.get(probe.id) != probe || Objects.equals(probe.value, current)) return false;
        if (current == null) entries.remove(probe.id);
        else entries.put(probe.id, new Probe<>(probe.id, current));
        return true;
    }

    // An unavailable old document ID is not proof of deletion. Emit one
    // refresh hint and retire only this probe; a fresh list supplies new IDs.
    synchronized boolean invalidated(Probe<T> probe) {
        if (entries.get(probe.id) != probe) return false;
        entries.remove(probe.id);
        return true;
    }

    synchronized int size() { return entries.size(); }
}
