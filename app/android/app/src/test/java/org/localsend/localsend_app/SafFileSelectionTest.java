package org.localsend.localsend_app;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class SafFileSelectionTest {
    static final String A = "content://provider/document/opaque%3Aid";
    static SafFolderTree.Node node(String uri, String name, Long size, boolean dir, boolean virtual) {
        return new SafFolderTree.Node(uri, name, uri, dir, virtual, size, 0L);
    }
    static final class Source implements SafFileSelection.Provider {
        Map<String, SafFolderTree.Node> files = new HashMap<>();
        int queries, grants, checks, cancelAt = -1;
        boolean denied, failed;
        public void check() throws Exception {
            if (++checks == cancelAt) throw new SafFolderTree.Failure("cancelled");
        }
        public void persistRead(String uri) {
            grants++;
            if (denied) throw new SecurityException("revoked");
        }
        public SafFolderTree.Node query(String uri) throws Exception {
            queries++;
            if (failed) throw new SafFolderTree.Failure("unavailable");
            return files.get(uri);
        }
    }
    static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    static void failure(Source source, List<String> uris, String code) throws Exception {
        try { SafFileSelection.read(source, uris); throw new AssertionError("accepted " + code); }
        catch (SafFolderTree.Failure error) { check(error.code.equals(code)); }
    }
    static Source one(SafFolderTree.Node node) { Source s = new Source(); s.files.put(A, node); return s; }
    static final class Grant implements SafFileSelection.ReadGrant {
        boolean allowed, retain = true;
        int acquisitions;
        public boolean persisted() { return allowed; }
        public void acquire() { acquisitions++; allowed = retain; }
    }
    static void deniedGrant(Grant grant, boolean read, boolean persist) throws Exception {
        try { SafFileSelection.ensurePersistentRead(grant, read, persist); throw new AssertionError("accepted missing grant"); }
        catch (SecurityException expected) { }
    }
    public static void main(String[] args) throws Exception {
        Grant existing = new Grant(); existing.allowed = true;
        SafFileSelection.ensurePersistentRead(existing, false, false); check(existing.acquisitions == 0);
        Grant fresh = new Grant(); SafFileSelection.ensurePersistentRead(fresh, true, true);
        check(fresh.allowed && fresh.acquisitions == 1);
        Grant missingRead = new Grant(); deniedGrant(missingRead, false, true); check(missingRead.acquisitions == 0);
        Grant transientGrant = new Grant(); deniedGrant(transientGrant, true, false); check(transientGrant.acquisitions == 0);
        Grant notRetained = new Grant(); notRetained.retain = false;
        deniedGrant(notRetained, true, true); check(notRetained.acquisitions == 1);

        Source source = one(node(A, " 中文 %.txt ", 7L, false, false));
        List<SafFileSelection.File> result = SafFileSelection.read(source, Arrays.asList(A, A));
        check(result.size() == 1 && result.get(0).uri.equals(A) && result.get(0).name.equals(" 中文 %.txt "));
        check(result.get(0).size == 7 && result.get(0).modified == null && source.queries == 1 && source.grants == 1);
        result = SafFileSelection.read(one(node(A, "empty", 0L, false, false)), Collections.singletonList(A));
        check(result.get(0).size == 0);
        failure(one(node(A, "unknown", null, false, false)), Collections.singletonList(A), "unsupported");
        failure(one(node(A, "negative", -1L, false, false)), Collections.singletonList(A), "unsupported");
        failure(one(node(A, "huge", 9007199254740992L, false, false)), Collections.singletonList(A), "unsupported");
        failure(one(node(A, "folder", 0L, true, false)), Collections.singletonList(A), "unsupported");
        failure(one(node(A, "virtual", 0L, false, true)), Collections.singletonList(A), "unsupported");
        failure(one(node(A, "../bad", 0L, false, false)), Collections.singletonList(A), "invalid_name");
        failure(one(node("content://other/replacement", "x", 0L, false, false)), Collections.singletonList(A), "invalid");
        failure(new Source(), Collections.singletonList(A), "unavailable");
        failure(new Source(), Collections.emptyList(), "invalid");
        failure(new Source(), Collections.singletonList(null), "invalid");
        failure(new Source(), Collections.nCopies(SafFileSelection.MAX_FILES + 1, A), "limit");
        Source denied = new Source(); denied.denied = true;
        try { SafFileSelection.read(denied, Collections.singletonList(A)); throw new AssertionError(); }
        catch (SecurityException expected) { check(denied.queries == 0); }
        Source cancelled = new Source(); cancelled.cancelAt = 1;
        failure(cancelled, Collections.singletonList(A), "cancelled"); check(cancelled.grants == 0);
        Source cancelAfterGrant = new Source(); cancelAfterGrant.cancelAt = 3;
        failure(cancelAfterGrant, Collections.singletonList(A), "cancelled"); check(cancelAfterGrant.queries == 0);
        Source lateCancel = one(node(A, "x", 1L, false, false)); lateCancel.cancelAt = 4;
        failure(lateCancel, Collections.singletonList(A), "cancelled"); check(lateCancel.queries == 1);
        Source batch = one(node(A, "x", 1L, false, false));
        failure(batch, Arrays.asList(A, "content://provider/missing"), "unavailable"); check(batch.queries == 2);
        Source failed = new Source(); failed.failed = true;
        failure(failed, Collections.singletonList(A), "unavailable");
        Source many = new Source(); List<String> uris = new ArrayList<>();
        for (int i = 0; i < 5000; i++) {
            String uri = "content://provider/document/opaque-" + i;
            uris.add(uri); many.files.put(uri, node(uri, "文件" + i, (long) i, false, false));
        }
        check(SafFileSelection.read(many, uris).size() == 5000 && many.queries == 5000);
        Source huge = new Source(); uris = new ArrayList<>();
        for (int i = 0; i < 300; i++) {
            String uri = "content://provider/" + "x".repeat(15000) + i;
            uris.add(uri); huge.files.put(uri, node(uri, "file", 1L, false, false));
        }
        failure(huge, uris, "limit");
        System.out.println("PASS 26 file-selection cases (including 5 persisted grant cases): real zero/unknown size, opaque URI, duplicate, grant denial, cancellation, atomic failure, 5000 files and budgets");
    }
}
