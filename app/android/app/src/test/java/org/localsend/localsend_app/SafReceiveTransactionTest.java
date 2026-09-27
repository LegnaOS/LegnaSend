package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Host contract checks, not Android provider acceptance. */
public final class SafReceiveTransactionTest {
    static int checks;
    static final class Fake implements SafReceiveTransaction.Backend, SafReceiveTransaction.Journal {
        final Map<String, SafReceiveTransaction.Record> records = new LinkedHashMap<>();
        final Map<String, String> documents = new HashMap<>();
        final List<String> names = new ArrayList<>(), events = new ArrayList<>();
        boolean granted = true, identityFailure, probeFailure, deleteFailure, changed, verificationFailure, copyFailure, prepareFailure, closeUncertain;
        int publications, releases, closes;
        int createFailureAt, creates, probes, deletes;
        public void authorize(String tree, String parent) throws IOException {
            events.add("authorize");
            if (!granted) throw new SafReceiveTransaction.Failure("PERMISSION_DENIED", "Grant revoked");
        }
        public String create(String parent, String name) throws IOException {
            creates++; events.add("create");
            if (creates == createFailureAt) throw new IOException("Provider offline");
            names.add(name); String uri = "content://provider/opaque-" + creates;
            documents.put(uri, "proof-" + creates); return uri;
        }
        public String identity(String uri) throws IOException {
            events.add("identity");
            if (identityFailure) throw new IOException("Open failed after creation");
            return documents.get(uri);
        }
        public void probe(String uri, String identity) throws IOException {
            probes++; events.add("probe"); eq(documents.get(uri), identity);
            if (probeFailure) throw new SafReceiveTransaction.Failure("CAPABILITY_UNSUPPORTED", "Seek or lock failure");
        }
        public boolean deleteOwned(String tree, String parent, String uri, String identity) throws IOException {
            if (deleteFailure) throw new IOException("Offline");
            if (changed || !Objects.equals(documents.get(uri), identity)) return false;
            deletes++; documents.remove(uri); return true;
        }
        public void save(SafReceiveTransaction.Record r) { events.add("save"); records.put(r.id, r.copy()); }
        public SafReceiveTransaction.Record load(String id) { SafReceiveTransaction.Record r = records.get(id); return r == null ? null : r.copy(); }
        public void remove(String id) { records.remove(id); }
        public void prepareReceive(SafReceiveTransaction.Record r) throws IOException {
            if (prepareFailure) throw new IOException("Opening receive pair failed");
            eq(records.get(r.id).state, SafReceiveTransaction.State.RECEIVING);
            eq(records.get(r.id).lease, r.lease);
            r.cache = new SafReceiveTransaction.Document(r.cache.uri, "receiving-cache");
            r.staging = new SafReceiveTransaction.Document(r.staging.uri, "receiving-stage");
            documents.put(r.cache.uri, r.cache.identity); documents.put(r.staging.uri, r.staging.identity);
        }
        public void verifyStaging(SafReceiveTransaction.Record r, long size, String sha) throws IOException {
            if (verificationFailure) throw new SafReceiveTransaction.Failure("CHECKSUM_MISMATCH", "Wrong staging bytes");
        }
        public String createPublication(SafReceiveTransaction.Record r) throws IOException {
            eq(records.get(r.id).state, SafReceiveTransaction.State.PUBLISHING);
            publications++; return create(r.parent, r.desiredName);
        }
        public String publicationIdentity(SafReceiveTransaction.Record r, String uri) {
            eq(records.get(r.id).output.uri, uri);
            return documents.get(uri);
        }
        public void copyPublication(SafReceiveTransaction.Record r, long size, String sha) throws IOException {
            eq(records.get(r.id).output.identity, documents.get(r.output.uri));
            if (copyFailure) throw new IOException("Destination copy interrupted");
            if (closeUncertain) throw new SafReceiveTransaction.PublicationUncertain("Provider final close outcome is unknown");
        }
        public boolean deleteFailedPublication(SafReceiveTransaction.Record r) throws IOException {
            eq(r.state, SafReceiveTransaction.State.PUBLICATION_FAILED);
            return deleteOwned(r.tree, r.parent, r.output.uri, r.output.identity);
        }
        public void releaseReceive(SafReceiveTransaction.Record r) { releases++; }
        public void closeReceive(SafReceiveTransaction.Record r) { closes++; }
        SafReceiveTransaction manager() { return new SafReceiveTransaction(this, this); }
    }
    interface Work { void run() throws IOException; }
    static void eq(Object got, Object expected) { checks++; if (!Objects.equals(got, expected)) throw new AssertionError(got + " != " + expected); }
    static void fails(String code, Work work) throws IOException {
        try { work.run(); throw new AssertionError("Expected " + code); }
        catch (IOException error) { if (code != null) eq(((SafReceiveTransaction.Failure) error).code, code); else checks++; }
    }
    static SafReceiveTransaction.Record begin(SafReceiveTransaction m) throws IOException {
        return m.begin("tree:opaque", "parent:actual", "already-exists.txt", "session", "file", "attempt");
    }
    public static void main(String[] args) throws IOException {
        Fake f = new Fake(); SafReceiveTransaction m = f.manager(); SafReceiveTransaction.Record r = begin(m);
        eq(r.state, SafReceiveTransaction.State.READY); eq(f.probes, 2); eq(f.creates, 2);
        eq(r.cache.uri, "content://provider/opaque-1"); eq(r.staging.uri, "content://provider/opaque-2");
        eq(f.names, Arrays.asList(".legnasend-receive-" + r.id + ".ls", ".legnasend-receive-" + r.id + ".part"));
        eq(f.names.contains(r.desiredName), false);
        eq(f.events.subList(0, 7), Arrays.asList("authorize", "save", "authorize", "create", "save", "identity", "save"));
        eq(f.records.get(r.id).cache.identity, "proof-1");
        r.state = SafReceiveTransaction.State.ABORTED;
        eq(f.records.get(r.id).state, SafReceiveTransaction.State.READY);
        SafReceiveTransaction.AbortResult aborted = m.abort(r.id);
        eq(aborted.complete, true); eq(aborted.deleted.size(), 2); eq(f.records.isEmpty(), true);
        eq(m.abort(r.id).deleted.size(), 0); eq(f.deletes, 2);

        Fake creation = new Fake(); creation.createFailureAt = 2;
        fails(null, () -> begin(creation.manager())); eq(creation.deletes, 1); eq(creation.documents.isEmpty(), true);
        Fake opening = new Fake(); opening.identityFailure = true;
        fails(null, () -> begin(opening.manager())); eq(opening.deletes, 0); eq(opening.records.size(), 1);
        SafReceiveTransaction.Record unknown = opening.records.values().iterator().next();
        eq(unknown.cache.identity, null); eq(unknown.state, SafReceiveTransaction.State.ABORT_PENDING);
        eq(opening.manager().abort(unknown.id).reasons, Collections.singletonList("OWNERSHIP_UNPROVEN"));
        Fake probe = new Fake(); probe.probeFailure = true;
        fails("CAPABILITY_UNSUPPORTED", () -> begin(probe.manager())); eq(probe.creates, 1); eq(probe.deletes, 1);
        Fake denied = new Fake(); denied.granted = false;
        fails("PERMISSION_DENIED", () -> begin(denied.manager())); eq(denied.creates, 0);
        Fake revoked = new Fake(); SafReceiveTransaction.Record rr = begin(revoked.manager()); revoked.granted = false;
        eq(revoked.manager().abort(rr.id).retained.size(), 2); eq(revoked.deletes, 0);
        revoked.granted = true; eq(revoked.manager().abort(rr.id).complete, true);
        Fake replaced = new Fake(); SafReceiveTransaction.Record replacement = begin(replaced.manager()); replaced.changed = true;
        eq(replaced.manager().abort(replacement.id).complete, false); eq(replaced.deletes, 0);
        Fake offline = new Fake(); SafReceiveTransaction.Record pending = begin(offline.manager()); offline.deleteFailure = true;
        eq(offline.manager().abort(pending.id).complete, false); eq(offline.records.size(), 1);
        offline.deleteFailure = false; eq(offline.manager().abort(pending.id).deleted.size(), 2);

        Fake leased = new Fake(); SafReceiveTransaction lm = leased.manager(); SafReceiveTransaction.Record active = begin(lm);
        fails("STALE_HANDOFF", () -> lm.acquireLease(active.id, "session", "file", "old-attempt"));
        String lease = lm.acquireLease(active.id, "session", "file", "attempt");
        fails("STALE_HANDOFF", () -> lm.acquireLease(active.id, "session", "file", "attempt"));
        eq(lm.abort(active.id).reasons, Collections.singletonList("ACTIVE_LEASE")); eq(leased.deletes, 0);
        fails("STALE_HANDOFF", () -> lm.releaseLease(active.id, "old-lease")); lm.releaseLease(active.id, lease);
        String next = lm.acquireLease(active.id, "session", "file", "attempt"); eq(lease.equals(next), false);
        fails("STALE_HANDOFF", () -> lm.releaseLease(active.id, lease)); lm.releaseLease(active.id, next);
        eq(lm.abort(active.id).complete, true);
        fails("STALE_HANDOFF", () -> lm.acquireLease(active.id, "session", "file", "attempt"));
        Fake invalid = new Fake();
        try { invalid.manager().begin("tree", "parent", "../final", "s", "f", "a"); throw new AssertionError("Invalid name accepted"); }
        catch (SafDirectoryResolver.Failure expected) { eq(expected.code, "INVALID_ARGUMENT"); }
        eq(invalid.creates, 0);
        publicationChecks();
        System.out.println("SAF receive transaction: " + checks + " assertions passed");
    }
    static void publicationChecks() throws IOException {
        String hash = String.join("", Collections.nCopies(64, "a"));
        Fake f = new Fake(); SafReceiveTransaction m = f.manager(); SafReceiveTransaction.Record ready = begin(m);
        SafReceiveTransaction.Record receiving = m.openReceive(ready.id, "session", "file", "attempt");
        eq(receiving.state, SafReceiveTransaction.State.RECEIVING);
        eq(f.records.get(ready.id).cache.identity, "receiving-cache");
        fails("STALE_HANDOFF", () -> m.openReceive(ready.id, "session", "file", "attempt"));
        fails("INVALID_ARGUMENT", () -> m.publish(ready.id, receiving.lease, "core-1", -1, hash));
        fails("INVALID_ARGUMENT", () -> m.publish(ready.id, receiving.lease, "core-1", 5, "bad"));
        fails("STALE_HANDOFF", () -> m.publish(ready.id, "wrong-lease", "core-1", 5, hash));
        eq(m.abort(ready.id).complete, false); eq(f.deletes, 0); eq(f.closes, 0);
        fails("STALE_HANDOFF", () -> m.abortReceiving(ready.id, "wrong-lease")); eq(f.closes, 0);
        SafReceiveTransaction.Record receipt = m.publish(ready.id, receiving.lease, "core-1", 5, hash.toUpperCase(Locale.ROOT));
        eq(receipt.state, SafReceiveTransaction.State.PUBLISHED); eq(receipt.sha256, hash); eq(receipt.size, 5L);
        eq(receipt.output.uri, "content://provider/opaque-3"); eq(f.publications, 1);
        eq(m.publish(ready.id, receiving.lease, "core-1", 5, hash).output.uri, receipt.output.uri);
        eq(f.publications, 1);
        fails("STALE_PUBLICATION", () -> m.publish(ready.id, receiving.lease, "core-2", 5, hash));
        fails("STALE_PUBLICATION", () -> m.publish(ready.id, receiving.lease, "core-1", 6, hash));
        eq(m.abort(ready.id).complete, false); eq(f.deletes, 0);
        SafReceiveTransaction.AbortResult publishedCleanup = m.finalizeReceive(ready.id, receiving.lease);
        eq(publishedCleanup.deleted.size(), 1); eq(f.releases, 1); eq(f.closes, 1);
        eq(publishedCleanup.retained, Collections.singletonList(receipt.staging.uri));
        eq(publishedCleanup.reasons, Collections.singletonList("PUBLISHED_STAGING_CLEANUP_RETAINED"));
        eq(f.records.get(ready.id).receiveReleased, true);
        eq(f.documents.size(), 2); eq(f.documents.containsKey(receipt.output.uri), true);
        eq(f.records.get(ready.id).state, SafReceiveTransaction.State.PUBLISHED);
        eq(m.finalizeReceive(ready.id, receiving.lease).deleted.size(), 0); eq(f.releases, 1);
        eq(m.publish(ready.id, receiving.lease, "core-1", 5, hash).output.uri, receipt.output.uri);
        eq(m.abortReceiving(ready.id, receiving.lease).complete, false); eq(f.documents.size(), 2);

        Fake failed = new Fake(); SafReceiveTransaction fm = failed.manager(); SafReceiveTransaction.Record fr = begin(fm);
        SafReceiveTransaction.Record ff = fm.openReceive(fr.id, "session", "file", "attempt");
        failed.verificationFailure = true;
        fails("CHECKSUM_MISMATCH", () -> fm.publish(fr.id, ff.lease, "core", 5, hash));
        eq(failed.publications, 0); eq(failed.records.get(fr.id).state, SafReceiveTransaction.State.RECEIVING);
        eq(fm.abortReceiving(fr.id, ff.lease).complete, true); eq(failed.documents.size(), 0);

        Fake unopened = new Fake(); SafReceiveTransaction um = unopened.manager(); SafReceiveTransaction.Record ur = begin(um);
        unopened.prepareFailure = true;
        fails(null, () -> um.openReceive(ur.id, "session", "file", "attempt"));
        eq(unopened.releases, 1); eq(unopened.closes, 1); eq(unopened.documents.isEmpty(), true); eq(unopened.records.isEmpty(), true);
        eq(um.abort(ur.id).complete, true);

        Fake partial = new Fake(); SafReceiveTransaction pm = partial.manager(); SafReceiveTransaction.Record pr = begin(pm);
        SafReceiveTransaction.Record pp = pm.openReceive(pr.id, "session", "file", "attempt"); partial.copyFailure = true;
        fails(null, () -> pm.publish(pr.id, pp.lease, "core", 5, hash));
        eq(partial.records.get(pr.id).state, SafReceiveTransaction.State.PUBLICATION_FAILED);
        fails("STALE_PUBLICATION", () -> pm.publish(pr.id, pp.lease, "core", 5, hash));
        eq(pm.abortReceiving(pr.id, pp.lease).complete, true);
        eq(partial.documents.size(), 0); eq(partial.deletes, 3); eq(partial.closes, 1);

        Fake uncertain = new Fake(); SafReceiveTransaction cm = uncertain.manager(); SafReceiveTransaction.Record cr = begin(cm);
        SafReceiveTransaction.Record cc = cm.openReceive(cr.id, "session", "file", "attempt"); uncertain.closeUncertain = true;
        fails(null, () -> cm.publish(cr.id, cc.lease, "core", 5, hash));
        eq(uncertain.records.get(cr.id).state, SafReceiveTransaction.State.PUBLISHING);
        eq(cm.abortReceiving(cr.id, cc.lease).reasons, Collections.singletonList("PUBLICATION_AMBIGUOUS"));
        eq(uncertain.documents.size(), 3); eq(uncertain.deletes, 0); eq(uncertain.closes, 1);

        Fake dirty = new Fake(); SafReceiveTransaction dm = dirty.manager(); SafReceiveTransaction.Record dr = begin(dm);
        SafReceiveTransaction.Record dd = dm.openReceive(dr.id, "session", "file", "attempt");
        dm.publish(dr.id, dd.lease, "core", 5, hash); dirty.deleteFailure = true;
        eq(dm.finalizeReceive(dr.id, dd.lease).complete, false); eq(dirty.closes, 1);
        eq(dirty.records.get(dr.id).state, SafReceiveTransaction.State.PUBLISHED);
        dirty.deleteFailure = false; eq(dm.finalizeReceive(dr.id, dd.lease).complete, false);
        eq(dirty.documents.size(), 2);
    }
}
