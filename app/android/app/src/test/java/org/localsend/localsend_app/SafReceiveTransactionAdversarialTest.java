package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Fault injection against provider-neutral boundaries; not Android device acceptance. */
public final class SafReceiveTransactionAdversarialTest {
    private static int checks;
    private static final String TREE = "tree:selected%2Froot";
    private static final String PARENT = "provider:opaque-parent-α";
    private static final class MemoryJournal implements SafReceiveTransaction.Journal {
        final Map<String, SafReceiveTransaction.Record> records = new LinkedHashMap<>();
        int saves, failSave = -1;
        boolean failRemove;
        public void save(SafReceiveTransaction.Record record) throws IOException {
            if (++saves == failSave) throw new IOException("journal unavailable");
            records.put(record.id, record.copy());
        }
        public SafReceiveTransaction.Record load(String id) {
            SafReceiveTransaction.Record found = records.get(id);
            return found == null ? null : found.copy();
        }
        public void remove(String id) throws IOException {
            if (failRemove) throw new IOException("journal deletion failed");
            records.remove(id);
        }
        String onlyId() { eq(records.size(), 1); return records.keySet().iterator().next(); }
    }
    private static final class Provider implements SafReceiveTransaction.Backend {
        final Map<String, String> documents = new LinkedHashMap<>();
        final List<String> createdNames = new ArrayList<>(), opened = new ArrayList<>(), deleted = new ArrayList<>();
        final Set<String> owned = new HashSet<>();
        int creates, authorizations, revokeAt = -1;
        boolean denied, failIdentity, failProbe, substituteExisting, aliasCache, directoryFailure;
        Provider() { documents.put("provider:USER-FILE", "original-user-identity"); }
        public void authorize(String tree, String parent) throws IOException {
            eq(tree, TREE); eq(parent, PARENT);
            if (++authorizations == revokeAt) denied = true;
            if (denied && directoryFailure) throw new SafDirectoryResolver.Failure("PERMISSION_DENIED", "revoked");
            if (denied) throw new SafReceiveTransaction.Failure("PERMISSION_DENIED", "revoked");
        }
        public String create(String parent, String name) {
            eq(parent, PARENT); createdNames.add(name); creates++;
            if (substituteExisting) return "provider:USER-FILE";
            if (aliasCache && creates == 2) return "provider:actual%2Fopaque-1";
            String uri = "provider:actual%2Fopaque-" + creates;
            documents.put(uri, "ownership-proof-" + creates); owned.add(uri); return uri;
        }
        public String identity(String uri) throws IOException {
            if (failIdentity || !owned.contains(uri)) throw new SafReceiveTransaction.Failure("OWNERSHIP_UNPROVEN", "not proven new");
            return documents.get(uri);
        }
        public void probe(String uri, String identity) throws IOException {
            eq(documents.get(uri), identity); opened.add(uri);
            if (failProbe) throw new SafReceiveTransaction.Failure("CAPABILITY_UNSUPPORTED", "pipe descriptor");
        }
        public boolean deleteOwned(String tree, String parent, String uri, String identity) {
            eq(tree, TREE); eq(parent, PARENT);
            if (!Objects.equals(documents.get(uri), identity) || !owned.contains(uri)) return false;
            documents.remove(uri); owned.remove(uri); deleted.add(uri); return true;
        }
    }
    private static final class Fixture {
        final Provider provider = new Provider();
        final MemoryJournal journal = new MemoryJournal();
        final SafReceiveTransaction transaction = new SafReceiveTransaction(provider, journal);
        SafReceiveTransaction.Record begin() throws IOException {
            return transaction.begin(TREE, PARENT, "中文 % original.txt", "session", "file", "attempt");
        }
    }
    @FunctionalInterface private interface Operation { void run() throws IOException; }
    private static void fails(String message, Operation operation) throws IOException {
        try { operation.run(); throw new AssertionError("Expected " + message); }
        catch (IOException error) { eq(error.getMessage(), message); }
    }
    private static void eq(Object actual, Object expected) {
        checks++; if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
    }
    private static void truth(boolean value) { eq(value, true); }
    public static void main(String[] args) throws IOException {
        Fixture initial = new Fixture(); initial.journal.failSave = 1;
        fails("journal unavailable", initial::begin);
        eq(initial.provider.creates, 0); eq(initial.journal.records.size(), 0);

        // Only actual opaque IDs are opened. A returned record is an isolated snapshot.
        Fixture normal = new Fixture(); SafReceiveTransaction.Record record = normal.begin();
        eq(record.cache.uri, "provider:actual%2Fopaque-1"); eq(record.staging.uri, "provider:actual%2Fopaque-2");
        eq(normal.provider.opened, Arrays.asList(record.cache.uri, record.staging.uri));
        truth(normal.provider.createdNames.get(0).endsWith(".ls")); truth(normal.provider.createdNames.get(1).endsWith(".part"));
        truth(!normal.provider.createdNames.contains(record.desiredName));
        record.cache = new SafReceiveTransaction.Document("provider:USER-FILE", "original-user-identity");
        SafReceiveTransaction.AbortResult abort = normal.transaction.abort(record.id);
        eq(abort.deleted.size(), 2); truth(abort.complete);
        eq(normal.provider.documents.get("provider:USER-FILE"), "original-user-identity");
        truth(normal.transaction.abort(record.id).complete);

        // Unknown ownership after create/open failure is not deletion authority.
        Fixture unknown = new Fixture(); unknown.provider.failIdentity = true;
        fails("not proven new", unknown::begin);
        String unknownId = unknown.journal.onlyId(); eq(unknown.journal.load(unknownId).cache.identity, null);
        eq(unknown.provider.deleted.size(), 0); eq(unknown.provider.opened.size(), 0);
        abort = unknown.transaction.abort(unknownId);
        eq(abort.retained, Collections.singletonList("provider:actual%2Fopaque-1"));
        eq(abort.reasons, Collections.singletonList("OWNERSHIP_UNPROVEN"));

        Fixture existing = new Fixture(); existing.provider.substituteExisting = true;
        fails("not proven new", existing::begin);
        eq(existing.provider.opened.size(), 0); eq(existing.provider.deleted.size(), 0);
        eq(existing.provider.documents.get("provider:USER-FILE"), "original-user-identity");

        Fixture pipe = new Fixture(); pipe.provider.failProbe = true;
        fails("pipe descriptor", pipe::begin);
        eq(pipe.provider.deleted, Collections.singletonList("provider:actual%2Fopaque-1")); eq(pipe.journal.records.size(), 0);

        // Permission loss between the first and second create retains a retryable record.
        Fixture revoke = new Fixture(); revoke.provider.revokeAt = 3;
        fails("revoked", revoke::begin); String revokeId = revoke.journal.onlyId();
        eq(revoke.provider.creates, 1); eq(revoke.provider.deleted.size(), 0);
        revoke.provider.denied = false;
        abort = revoke.transaction.abort(revokeId); truth(abort.complete); eq(abort.deleted.size(), 1);

        // A failed post-create journal write must preserve URI without guessing ownership.
        Fixture postCreate = new Fixture(); postCreate.journal.failSave = 2;
        fails("journal unavailable", postCreate::begin); String postCreateId = postCreate.journal.onlyId();
        eq(postCreate.journal.load(postCreateId).cache.uri, "provider:actual%2Fopaque-1");
        eq(postCreate.journal.load(postCreateId).cache.identity, null); eq(postCreate.provider.deleted.size(), 0);

        // Live and replayed leases block cleanup; stale tokens cannot release a newer writer.
        Fixture lease = new Fixture(); record = lease.begin(); String id = record.id;
        String writer = lease.transaction.acquireLease(id, "session", "file", "attempt");
        SafReceiveTransaction replay = new SafReceiveTransaction(lease.provider, lease.journal);
        abort = replay.abort(id); eq(abort.deleted.size(), 0); truth(!abort.complete);
        eq(abort.reasons, Collections.singletonList("ACTIVE_LEASE"));
        fails("Lease does not own this transaction", () -> replay.releaseLease(id, "stale-writer")); eq(lease.provider.deleted.size(), 0);
        replay.releaseLease(id, writer); String next = replay.acquireLease(id, "session", "file", "attempt");
        fails("Lease does not own this transaction", () -> replay.releaseLease(id, writer));
        replay.releaseLease(id, next); truth(replay.abort(id).complete);

        // Delete succeeded but journal save failed: never delete a replacement reusing that URI.
        Fixture replaced = new Fixture(); record = replaced.begin(); String replacedId = record.id, cacheUri = record.cache.uri;
        replaced.journal.failSave = replaced.journal.saves + 2;
        fails("journal unavailable", () -> replaced.transaction.abort(replacedId));
        replaced.provider.documents.put(cacheUri, "new-user-replacement"); replaced.provider.owned.add(cacheUri);
        abort = replaced.transaction.abort(replacedId);
        truth(!abort.complete); eq(abort.deleted.size(), 1); eq(abort.retained, Collections.singletonList(cacheUri));
        eq(replaced.provider.documents.get(cacheUri), "new-user-replacement");
        eq(replaced.provider.documents.get("provider:USER-FILE"), "original-user-identity");
        // A broken provider cannot alias staging and cache into the same document.
        Fixture alias = new Fixture(); alias.provider.aliasCache = true;
        try { alias.begin(); throw new AssertionError("Expected aliased documents to fail"); }
        catch (SafReceiveTransaction.Failure error) { eq(error.code, "DOCUMENT_ALIAS"); }
        eq(alias.provider.opened.size(), 1);
        eq(alias.provider.deleted, Collections.singletonList("provider:actual%2Fopaque-1"));
        eq(alias.journal.records.size(), 0);

        // Failure to remove an already-cleaned journal is retryable without provider mutation.
        Fixture remove = new Fixture(); record = remove.begin(); String removeId = record.id;
        remove.journal.failRemove = true;
        fails("journal deletion failed", () -> remove.transaction.abort(removeId));
        eq(remove.journal.load(removeId).state, SafReceiveTransaction.State.ABORTED);
        eq(remove.provider.deleted.size(), 2); remove.journal.failRemove = false;
        truth(remove.transaction.abort(removeId).complete); eq(remove.provider.deleted.size(), 2);
        eq(remove.journal.records.size(), 0);

        // The actual adapter uses the directory Failure type; retain its machine-readable reason.
        Fixture typedFailure = new Fixture(); record = typedFailure.begin();
        typedFailure.provider.denied = true; typedFailure.provider.directoryFailure = true;
        abort = typedFailure.transaction.abort(record.id);
        eq(abort.reasons, Arrays.asList("PERMISSION_DENIED", "PERMISSION_DENIED"));
        eq(abort.deleted.size(), 0); eq(abort.retained.size(), 2);

        System.out.println("SAF adversarial transaction: " + checks + " assertions passed");
    }
    private SafReceiveTransactionAdversarialTest() {}
}
