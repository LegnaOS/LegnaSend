package org.localsend.localsend_app;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Provider-neutral fault injection, not Android provider/device acceptance. */
public final class SafReceivePublicationAdversarialTest {
    private static int checks;
    private static final byte[] DATA = "原始正文 % bytes".getBytes(StandardCharsets.UTF_8);
    private static final String HASH = hash(DATA);
    private static final class Journal implements SafReceiveTransaction.Journal {
        final Map<String, SafReceiveTransaction.Record> rows = new HashMap<>();
        boolean failPublished;
        public void save(SafReceiveTransaction.Record r) throws IOException {
            if (failPublished && r.state == SafReceiveTransaction.State.PUBLISHED) {
                failPublished = false; throw new IOException("published journal failed");
            }
            rows.put(r.id, r.copy());
        }
        public SafReceiveTransaction.Record load(String id) { SafReceiveTransaction.Record r = rows.get(id); return r == null ? null : r.copy(); }
        public void remove(String id) { rows.remove(id); }
    }
    private static final class Provider implements SafReceiveTransaction.Backend {
        final Map<String, byte[]> bytes = new HashMap<>();
        final Map<String, String> identities = new HashMap<>();
        final List<String> deleted = new ArrayList<>();
        int creates, publications, copies, releases, failedDeleteCalls;
        boolean denied, active, existingOutput, aliasOutput, mutate, failCopy, failPrepare, uncertain, allowFailedDelete, failDelete;
        Provider() { bytes.put("user:existing", new byte[] {11, 22, 33}); identities.put("user:existing", "user-owned"); }
        public void authorize(String tree, String parent) throws IOException {
            if (denied) throw new SafReceiveTransaction.Failure("PERMISSION_DENIED", "revoked");
        }
        public String create(String parent, String name) {
            String uri = "opaque:provider%2F" + ++creates;
            identities.put(uri, "owned-" + creates); bytes.put(uri, new byte[] {1}); return uri;
        }
        public String identity(String uri) { return identities.get(uri); }
        public void probe(String uri, String identity) { eq(identity, identities.get(uri)); }
        public boolean deleteOwned(String tree, String parent, String uri, String identity) {
            truth(!uri.equals("user:existing"));
            truth(!uri.startsWith("opaque:final")); // Final outputs require the dedicated proof-checked hook.
            if (!Objects.equals(identity, identities.get(uri))) return false;
            deleted.add(uri); bytes.remove(uri); identities.remove(uri); return true;
        }
        public void prepareReceive(SafReceiveTransaction.Record r) throws IOException {
            if (failPrepare) throw new IOException("handoff preparation failed");
            bytes.put(r.cache.uri, new byte[0]); bytes.put(r.staging.uri, DATA.clone());
        }
        public void verifyStaging(SafReceiveTransaction.Record r, long size, String sha256) throws IOException {
            byte[] actual = bytes.get(r.staging.uri);
            if (actual == null || actual.length != size || !hash(actual).equals(sha256)) throw new IOException("staging changed");
            if (mutate) bytes.put(r.staging.uri, new byte[] {7});
        }
        public String createPublication(SafReceiveTransaction.Record r) {
            publications++;
            if (existingOutput) return "user:existing";
            if (aliasOutput) return r.cache.uri;
            String uri = "opaque:final%2F" + publications;
            bytes.put(uri, new byte[0]); identities.put(uri, "published-owner"); return uri;
        }
        public String publicationIdentity(SafReceiveTransaction.Record r, String uri) throws IOException {
            if (uri.equals("user:existing")) throw new IOException("existing output");
            return identities.get(uri);
        }
        public void copyPublication(SafReceiveTransaction.Record r, long size, String sha256) throws IOException {
            copies++;
            if (failCopy) throw new IOException("provider copy failed");
            byte[] source = bytes.get(r.staging.uri);
            if (source.length != size || !hash(source).equals(sha256)) throw new IOException("source changed during publication");
            bytes.put(r.output.uri, source.clone());
            if (uncertain) throw new SafReceiveTransaction.PublicationUncertain("writer close/readback outcome unknown");
        }
        public boolean deleteFailedPublication(SafReceiveTransaction.Record r) throws IOException {
            failedDeleteCalls++;
            eq(r.state, SafReceiveTransaction.State.PUBLICATION_FAILED); truth(r.receiveReleased);
            truth(r.output != null); truth(!r.output.uri.equals("user:existing"));
            if (failDelete) throw new IOException("provider failed output deletion");
            if (!allowFailedDelete || r.cache == null || r.staging == null
                    || !Objects.equals(identities.get(r.output.uri), r.output.identity)) return false;
            deleted.add(r.output.uri); identities.remove(r.output.uri); bytes.remove(r.output.uri); return true;
        }
        public void releaseReceive(SafReceiveTransaction.Record r) throws IOException {
            if (active) throw new IOException("writer still owns descriptors");
            releases++;
        }
    }
    private static final class Fixture {
        final Journal journal = new Journal(); final Provider provider = new Provider();
        final SafReceiveTransaction transactions = new SafReceiveTransaction(provider, journal);
        SafReceiveTransaction.Record r;
        Fixture() throws IOException { r = transactions.begin("tree", "actual-parent", "中文 %.txt", "session", "file", "attempt"); }
        void open() throws IOException { r = transactions.openReceive(r.id, "session", "file", "attempt"); }
        SafReceiveTransaction.Record publish() throws IOException { return transactions.publish(r.id, r.lease, "core-attempt", DATA.length, HASH); }
    }
    @FunctionalInterface private interface Action { void run() throws IOException; }
    private static void fails(Action action) throws IOException {
        try { action.run(); throw new AssertionError("Failure was required"); } catch (IOException expected) { checks++; }
    }
    private static void eq(Object actual, Object expected) { checks++; if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected); }
    private static void truth(boolean actual) { eq(actual, true); }
    private static String hash(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (Exception impossible) { throw new AssertionError(impossible); }
    }
    private static void preserved(Fixture f) { truth(Arrays.equals(f.provider.bytes.get("user:existing"), new byte[] {11, 22, 33})); }
    public static void main(String[] args) throws IOException {
        Fixture success = new Fixture(); success.open(); SafReceiveTransaction.Record receipt = success.publish();
        eq(receipt.state, SafReceiveTransaction.State.PUBLISHED); eq(receipt.size, (long) DATA.length); eq(receipt.sha256, HASH);
        truth(Arrays.equals(success.provider.bytes.get(receipt.output.uri), DATA));
        success.publish(); eq(success.provider.publications, 1); eq(success.provider.copies, 1);
        fails(() -> success.transactions.publish(receipt.id, receipt.lease, "stale-core", DATA.length, HASH));
        fails(() -> success.transactions.publish(receipt.id, "stale-lease", "core-attempt", DATA.length, HASH));
        fails(() -> success.transactions.publish(receipt.id, receipt.lease, "core-attempt", DATA.length + 1, HASH));
        success.provider.active = true;
        fails(() -> success.transactions.finalizeReceive(receipt.id, receipt.lease)); eq(success.provider.deleted.size(), 0);
        success.provider.active = false;
        truth(!success.transactions.finalizeReceive(receipt.id, receipt.lease).complete);
        truth(!success.transactions.finalizeReceive(receipt.id, receipt.lease).complete);
        truth(!success.transactions.abortReceiving(receipt.id, receipt.lease).complete);
        eq(success.provider.deleted.size(), 1); eq(success.provider.releases, 1); eq(success.provider.failedDeleteCalls, 0);
        truth(Arrays.equals(success.provider.bytes.get(receipt.output.uri), DATA)); preserved(success);

        Fixture stale = new Fixture(); stale.open();
        fails(() -> stale.transactions.publish(stale.r.id, "wrong", "core", DATA.length, HASH));
        fails(() -> stale.transactions.publish(stale.r.id, stale.r.lease, "core", DATA.length, "0".repeat(64)));
        eq(stale.provider.publications, 0); eq(stale.provider.deleted.size(), 0);
        truth(stale.transactions.abortReceiving(stale.r.id, stale.r.lease).complete); preserved(stale);

        // Existing final files and cache aliases never become writable final outputs.
        for (boolean existing : new boolean[] {true, false}) {
            Fixture f = new Fixture(); f.open(); f.provider.existingOutput = existing; f.provider.aliasOutput = !existing;
            fails(f::publish); eq(f.provider.copies, 0);
            SafReceiveTransaction.AbortResult result = f.transactions.abortReceiving(f.r.id, f.r.lease);
            truth(!result.complete); eq(result.reasons, List.of("PUBLICATION_AMBIGUOUS")); eq(f.provider.deleted.size(), 0); preserved(f);
        }
        // Explicit failed copies use the dedicated proof-checked output cleanup hook.
        for (boolean mutate : new boolean[] {true, false}) {
            for (boolean allowDelete : new boolean[] {true, false}) {
                Fixture f = new Fixture(); f.open(); f.provider.mutate = mutate; f.provider.failCopy = !mutate;
                f.provider.allowFailedDelete = allowDelete;
                fails(f::publish); eq(f.journal.load(f.r.id).state, SafReceiveTransaction.State.PUBLICATION_FAILED);
                String output = f.journal.load(f.r.id).output.uri;
                fails(f::publish); eq(f.provider.publications, 1);
                SafReceiveTransaction.AbortResult cleanup = f.transactions.abortReceiving(f.r.id, f.r.lease);
                eq(cleanup.complete, allowDelete); eq(f.provider.failedDeleteCalls, 1);
                eq(f.provider.deleted.size(), allowDelete ? 3 : 2); eq(f.provider.bytes.containsKey(output), !allowDelete);
                if (allowDelete) eq(f.journal.load(f.r.id), null);
                else { eq(cleanup.retained, List.of(output)); eq(cleanup.reasons, List.of("OWNERSHIP_CHANGED_OR_UNAVAILABLE")); }
                preserved(f);
            }
        }
        // A changed identity or failed delete retains the output even with cleanup enabled.
        for (boolean replaced : new boolean[] {true, false}) {
            Fixture f = new Fixture(); f.open(); f.provider.failCopy = true; f.provider.allowFailedDelete = true;
            fails(f::publish); String output = f.journal.load(f.r.id).output.uri;
            if (replaced) {
                f.provider.identities.put(output, "new-user-file"); f.provider.bytes.put(output, new byte[] {77});
            } else f.provider.failDelete = true;
            SafReceiveTransaction.AbortResult cleanup = f.transactions.abortReceiving(f.r.id, f.r.lease);
            truth(!cleanup.complete); eq(cleanup.retained, List.of(output)); eq(f.provider.deleted.size(), 2);
            eq(f.provider.failedDeleteCalls, 1); truth(f.provider.bytes.containsKey(output));
            if (replaced) truth(Arrays.equals(f.provider.bytes.get(output), new byte[] {77}));
            preserved(f);
        }
        // Successful writes followed by uncertain close/readback keep all documents protected.
        Fixture uncertain = new Fixture(); uncertain.open(); uncertain.provider.uncertain = true; uncertain.provider.allowFailedDelete = true;
        fails(uncertain::publish); SafReceiveTransaction.Record uncertainRecord = uncertain.journal.load(uncertain.r.id);
        eq(uncertainRecord.state, SafReceiveTransaction.State.PUBLISHING);
        truth(Arrays.equals(uncertain.provider.bytes.get(uncertainRecord.output.uri), DATA));
        fails(uncertain::publish);
        SafReceiveTransaction.AbortResult uncertainCleanup = uncertain.transactions.abortReceiving(uncertain.r.id, uncertain.r.lease);
        truth(!uncertainCleanup.complete); eq(uncertainCleanup.retained.size(), 3);
        eq(uncertainCleanup.reasons, List.of("PUBLICATION_AMBIGUOUS"));
        eq(uncertain.provider.failedDeleteCalls, 0); eq(uncertain.provider.deleted.size(), 0); preserved(uncertain);
        // Failed durable acknowledgement after successful publication protects original bytes.
        Fixture durable = new Fixture(); durable.open(); durable.journal.failPublished = true;
        fails(durable::publish); SafReceiveTransaction.Record ambiguous = durable.journal.load(durable.r.id);
        truth(Arrays.equals(durable.provider.bytes.get(ambiguous.output.uri), DATA));
        fails(durable::publish); truth(!durable.transactions.abortReceiving(ambiguous.id, ambiguous.lease).complete);
        eq(durable.provider.publications, 1); eq(durable.provider.deleted.size(), 0); eq(durable.provider.failedDeleteCalls, 0); preserved(durable);

        Fixture revoke = new Fixture(); revoke.open(); SafReceiveTransaction.Record published = revoke.publish();
        revoke.provider.denied = true;
        truth(!revoke.transactions.finalizeReceive(published.id, published.lease).complete); eq(revoke.provider.deleted.size(), 0);
        revoke.provider.denied = false;
        truth(!revoke.transactions.finalizeReceive(published.id, published.lease).complete);
        truth(Arrays.equals(revoke.provider.bytes.get(published.output.uri), DATA)); preserved(revoke);

        Fixture changed = new Fixture(); changed.open(); SafReceiveTransaction.Record finalRecord = changed.publish();
        changed.provider.identities.put(changed.r.cache.uri, "replacement-user-owned");
        truth(!changed.transactions.finalizeReceive(finalRecord.id, finalRecord.lease).complete);
        truth(changed.provider.bytes.containsKey(changed.r.cache.uri)); eq(changed.provider.deleted.size(), 0);
        truth(Arrays.equals(changed.provider.bytes.get(finalRecord.output.uri), DATA)); preserved(changed);

        Fixture prepare = new Fixture(); prepare.provider.failPrepare = true;
        fails(prepare::open); eq(prepare.provider.publications, 0); eq(prepare.provider.deleted.size(), 2); preserved(prepare);
        System.out.println("SAF publication adversarial: " + checks + " assertions passed");
    }
    private SafReceivePublicationAdversarialTest() {}
}
