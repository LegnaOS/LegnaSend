package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Pure transaction regression with provider fault injection, not a device/provider test. */
public final class SafReceiveProbeCleanupTest {
    private static int checks;
    private static void eq(Object actual, Object expected) {
        checks++;
        if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
    }
    private static final class Fixture implements SafReceiveTransaction.Backend, SafReceiveTransaction.Journal {
        final Map<String, SafReceiveTransaction.Record> journal = new HashMap<>();
        final Map<String, byte[]> documents = new HashMap<>();
        final Map<String, String> proofs = new HashMap<>();
        final List<String> events = new ArrayList<>();
        final SafReceiveTransaction manager = new SafReceiveTransaction(this, this);
        SafReceiveTransaction.Record record;
        boolean granted = true, witness, released, transportClosed, failDelete;
        int created;
        Fixture() throws IOException {
            documents.put("user:existing", new byte[] {7, 8});
            proofs.put("user:existing", "user-owned");
            record = manager.begin("tree", "opaque-parent", "result.txt", "session", "file", "attempt");
            record = manager.openReceive(record.id, "session", "file", "attempt");
            eq(record.state, SafReceiveTransaction.State.RECEIVING);
        }
        public void authorize(String tree, String parent) throws IOException {
            if (!granted) throw new SafReceiveTransaction.Failure("PERMISSION_DENIED", "revoked");
        }
        public String create(String parent, String name) {
            String uri = "content://provider/opaque-" + ++created;
            documents.put(uri, new byte[] {1}); proofs.put(uri, "proof-" + created); return uri;
        }
        public String identity(String uri) { return proofs.get(uri); }
        public void probe(String uri, String identity) { eq(proofs.get(uri), identity); }
        public void prepareReceive(SafReceiveTransaction.Record record) {
            witness = true;
            documents.put(record.cache.uri, new byte[0]); documents.put(record.staging.uri, new byte[0]);
        }
        void consumeProbe(boolean supported) {
            // Models the Rust probe ownership contract: success AND failure consume
            // both transferred handles without writes. Native witness stays alive.
            eq(witness, true); eq(transportClosed, false);
            eq(documents.get(record.cache.uri).length, 0); eq(documents.get(record.staging.uri).length, 0);
            transportClosed = true;
            events.add(supported ? "probe-success-closed" : "probe-failed-closed");
        }
        public void releaseReceive(SafReceiveTransaction.Record record) {
            // This assertion is the caller contract. Android releaseReceive trusts
            // the caller; it does not independently inspect Rust handle ownership.
            eq(transportClosed, true); eq(witness, true);
            released = true; events.add("release");
        }
        public boolean deleteOwned(String tree, String parent, String uri, String identity) throws IOException {
            eq(released, true); eq(transportClosed, true);
            if (!witness || !Objects.equals(proofs.get(uri), identity)) return false;
            if (uri.equals(record.cache.uri) && documents.get(uri).length != 0)
                throw new IOException("Unknown cache bytes are not the empty probe");
            if (failDelete) throw new IOException("provider unavailable");
            eq(uri.equals("user:existing"), false);
            events.add("delete"); documents.remove(uri); proofs.remove(uri); return true;
        }
        public void closeReceive(SafReceiveTransaction.Record record) {
            eq(released, true); events.add("close"); witness = false;
        }
        public void save(SafReceiveTransaction.Record record) { journal.put(record.id, record.copy()); }
        public SafReceiveTransaction.Record load(String id) { return journal.containsKey(id) ? journal.get(id).copy() : null; }
        public void remove(String id) { journal.remove(id); }
        SafReceiveTransaction.AbortResult finish() throws IOException { return manager.abortReceiving(record.id, record.lease); }
        void userUntouched() { eq(Arrays.equals(documents.get("user:existing"), new byte[] {7, 8}), true); }
    }
    public static void main(String[] args) throws IOException {
        for (boolean supported : new boolean[] {true, false}) {
            Fixture f = new Fixture();
            // A capability failure still closes the probe descriptors and cleans
            // only these two freshly owned empty documents, not final output.
            f.consumeProbe(supported);
            SafReceiveTransaction.AbortResult result = f.finish();
            eq(result.complete, true); eq(result.deleted.size(), 2); eq(result.retained.size(), 0);
            eq(f.documents.size(), 1); eq(f.journal.size(), 0); eq(f.witness, false);
            eq(f.events, Arrays.asList(supported ? "probe-success-closed" : "probe-failed-closed", "release", "delete", "delete", "close"));
            f.userUntouched();
            // The real receiver creates a NEW transaction; no cached capability
            // fixture or its lease is reused as the actual writer target.
            SafReceiveTransaction.Record actual = f.manager.begin("tree", "opaque-parent", "result.txt", "session", "file", "actual-attempt");
            eq(actual.id.equals(f.record.id), false); eq(actual.cache.uri.equals(f.record.cache.uri), false);
            eq(actual.staging.uri.equals(f.record.staging.uri), false);
        }
        Fixture denied = new Fixture(); denied.consumeProbe(true); denied.granted = false;
        SafReceiveTransaction.AbortResult retained = denied.finish();
        eq(retained.complete, false); eq(retained.deleted.size(), 0); eq(retained.retained.size(), 2);
        eq(retained.reasons, Arrays.asList("PERMISSION_DENIED", "PERMISSION_DENIED"));
        eq(denied.witness, false); eq(denied.journal.size(), 1); denied.userUntouched();
        // Restoring the grant does not restore a closed in-process witness.
        denied.granted = true; eq(denied.manager.abort(denied.record.id).complete, false);
        eq(denied.documents.size(), 3);

        Fixture failed = new Fixture(); failed.consumeProbe(false); failed.failDelete = true;
        retained = failed.finish(); eq(retained.complete, false); eq(retained.retained.size(), 2);
        eq(failed.witness, false); eq(failed.journal.size(), 1); failed.userUntouched();

        Fixture changed = new Fixture(); changed.consumeProbe(true);
        changed.proofs.put(changed.record.staging.uri, "replacement-user-file");
        changed.documents.put(changed.record.staging.uri, new byte[] {99});
        retained = changed.finish(); eq(retained.complete, false); eq(retained.deleted, Collections.singletonList(changed.record.cache.uri));
        eq(retained.retained, Collections.singletonList(changed.record.staging.uri));
        eq(changed.documents.get(changed.record.staging.uri)[0], (byte) 99); eq(changed.witness, false); changed.userUntouched();

        Fixture alteredCache = new Fixture(); alteredCache.consumeProbe(true);
        alteredCache.documents.put(alteredCache.record.cache.uri, new byte[] {99});
        retained = alteredCache.finish(); eq(retained.complete, false);
        eq(retained.retained, Collections.singletonList(alteredCache.record.cache.uri));
        eq(alteredCache.documents.get(alteredCache.record.cache.uri)[0], (byte) 99);
        eq(alteredCache.witness, false); alteredCache.userUntouched();

        Fixture stale = new Fixture(); stale.consumeProbe(true);
        try { stale.manager.abortReceiving(stale.record.id, UUID.randomUUID().toString()); throw new AssertionError("stale lease accepted"); }
        catch (SafReceiveTransaction.Failure error) { eq(error.code, "STALE_HANDOFF"); }
        eq(stale.released, false); eq(stale.witness, true); eq(stale.documents.size(), 3);
        eq(stale.finish().complete, true); stale.userUntouched();
        System.out.println("SAF probe cleanup: " + checks + " assertions passed; provider-neutral lifecycle simulation, not an Android device test");
    }
}
