package org.localsend.localsend_app;

public final class SafWorkspaceChangeHintTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        SafWorkspaceChangeHint hint = new SafWorkspaceChangeHint();
        check(!hint.observe(null)); check(!hint.observe(0L)); check(!hint.observe(-1L));
        check(hint.observe(123L)); check(!hint.observe(123L)); check(hint.observe(124L));
        check(hint.observe(122L)); check(hint.observe(null)); check(!hint.observe(null));
        SafWorkspaceChangeHint other = new SafWorkspaceChangeHint();
        check(!other.observe(122L)); check(hint.observe(122L));
        System.out.println("PASS: first baseline, unknown values, forward/backward changes, missing metadata, independent scope");
    }
}
