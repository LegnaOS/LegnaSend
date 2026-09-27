package org.localsend.localsend_app;

import java.util.List;

public final class SafWorkspaceEntryHintsTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        SafWorkspaceEntryHints<String> hints = new SafWorkspaceEntryHints<>(3);
        check(hints.next(16).isEmpty());
        hints.listed("a", "a1"); hints.listed("b", "b1"); hints.listed("c", "c1");
        List<SafWorkspaceEntryHints.Probe<String>> first = hints.next(2);
        check(first.size() == 2 && first.get(0).id.equals("a") && first.get(1).id.equals("b"));
        check(hints.next(1).get(0).id.equals("c"));
        check(!hints.observed(first.get(0), "a1"));
        check(hints.observed(first.get(0), "a2"));
        check(!hints.observed(first.get(0), null)); // stale concurrent probe
        hints.listed("b", "b2");
        check(!hints.observed(first.get(1), "b1")); // listing supersedes late probe
        SafWorkspaceEntryHints.Probe<String> deleted = hints.next(3).stream().filter(p -> p.id.equals("b")).findFirst().get();
        check(hints.observed(deleted, null)); check(!hints.observed(deleted, null));
        check(hints.size() == 2);
        hints.listed("d", "d1"); hints.listed("e", "e1"); check(hints.size() == 3);
        check(hints.next(100).size() == 3); check(hints.next(0).isEmpty());
        SafWorkspaceEntryHints<String> independent = new SafWorkspaceEntryHints<>(3);
        independent.listed("e", "e1"); check(independent.size() == 1);
        SafWorkspaceEntryHints.Probe<String> unknown = independent.next(1).get(0);
        check(independent.invalidated(unknown)); check(!independent.invalidated(unknown));
        independent.listed("e", "new"); check(!independent.invalidated(unknown));
        check(independent.size() == 1);
        System.out.println("PASS: bounded retention, rotating probes, unchanged metadata, rename/edit/delete, stale result exclusion, scope isolation");
    }
}
