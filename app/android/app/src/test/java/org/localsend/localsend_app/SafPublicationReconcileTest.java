package org.localsend.localsend_app;

import java.io.IOException;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Consumer;

/** Private receipt state-machine checks; actual provider/FD/lock behavior requires device tests. */
public final class SafPublicationReconcileTest {
    static int checks;
    static void check(boolean value) { checks++; if (!value) throw new AssertionError(); }
    interface Work { void run() throws IOException; }
    static void fails(Work work) throws IOException {
        try { work.run(); throw new AssertionError("Expected failure"); } catch (IOException expected) { checks++; }
    }
    static final class Fixture implements SafReceiveTransaction.Journal {
        final SafReceiveTransactionTest.Fake backend = new SafReceiveTransactionTest.Fake();
        final SafReceiveTransaction transactions = new SafReceiveTransaction(backend, this);
        SafReceiveTransaction.Record record;
        boolean failSave;
        int saves;
        Fixture() {
            record = new SafReceiveTransaction.Record(UUID.randomUUID().toString(), "tree", "parent", "name", "session", "file", "attempt");
            record.state = SafReceiveTransaction.State.PUBLISHING;
            record.output = new SafReceiveTransaction.Document("output", "persistent-output-proof");
            record.cache = new SafReceiveTransaction.Document("cache", "cache-proof");
            record.staging = new SafReceiveTransaction.Document("staging", "stage-proof");
            record.coreAttempt = "core-attempt"; record.size = 42; record.sha256 = "a".repeat(64); record.lease = "old-private-lease";
            record.recoverySourceId = "old-source"; record.recoveryCompleted = true;
        }
        public void save(SafReceiveTransaction.Record value) throws IOException {
            if (failSave) throw new IOException("Atomic write failed");
            saves++; record = value.copy();
        }
        public SafReceiveTransaction.Record load(String id) { return record != null && record.id.equals(id) ? record.copy() : null; }
        public void remove(String id) { throw new AssertionError("Receipt removal forbidden"); }
        SafReceiveTransaction.Record candidate() throws IOException { return transactions.publicationReconcileCandidate(record.id); }
        void untouched() {
            check(backend.events.isEmpty()); check(backend.creates == 0 && backend.deletes == 0 && backend.publications == 0);
        }
    }
    static void ineligible(Consumer<SafReceiveTransaction.Record> mutate) throws IOException {
        Fixture f = new Fixture(); mutate.accept(f.record); check(f.candidate() == null); check(f.saves == 0); f.untouched();
    }
    static void changed(Consumer<SafReceiveTransaction.Record> mutate) throws IOException {
        Fixture f = new Fixture(); SafReceiveTransaction.Record snapshot = f.candidate(); mutate.accept(f.record);
        fails(() -> f.transactions.confirmPublicationReconcile(snapshot)); check(f.saves == 0); f.untouched();
    }
    public static void main(String[] args) throws IOException {
        for (SafReceiveTransaction.State state : SafReceiveTransaction.State.values()) {
            if (state != SafReceiveTransaction.State.PUBLISHING) ineligible(r -> r.state = state);
        }
        ineligible(r -> r.output = null);
        ineligible(r -> r.output = new SafReceiveTransaction.Document("output", null));
        ineligible(r -> r.output = new SafReceiveTransaction.Document("", "proof"));
        ineligible(r -> r.output = new SafReceiveTransaction.Document("cache", "proof"));
        ineligible(r -> r.output = new SafReceiveTransaction.Document("staging", "proof"));
        ineligible(r -> r.size = -1);
        ineligible(r -> r.sha256 = null);
        ineligible(r -> r.sha256 = "A".repeat(64));
        ineligible(r -> r.coreAttempt = "");
        ineligible(r -> r.coreAttempt = null);
        changed(r -> r.output = new SafReceiveTransaction.Document("replacement", r.output.identity));
        changed(r -> r.output = new SafReceiveTransaction.Document(r.output.uri, "other-proof"));
        changed(r -> r.size++);
        changed(r -> r.sha256 = "b".repeat(64));
        changed(r -> r.coreAttempt = "new-attempt");
        changed(r -> r.lease = "other-lease");
        changed(r -> r.receiveReleased = true);
        changed(r -> r.cache = null);
        changed(r -> r.staging = null);
        changed(r -> r.recoveryIdentity = "other-identity");
        changed(r -> r.recoverySourceId = "other-source");
        changed(r -> r.recoveryClaimId = "other-claim");
        changed(r -> r.recoverySupersededBy = "other-target");
        changed(r -> r.recoveryCompleted = false);
        changed(r -> r.recoveryRejected = true);
        changed(r -> r.recoveryLength = 49);
        changed(r -> r.recoverySha256 = "b".repeat(64));
        Fixture lost = new Fixture(); SafReceiveTransaction.Record snapshot = lost.candidate(); lost.record = null;
        fails(() -> lost.transactions.confirmPublicationReconcile(snapshot)); lost.untouched();
        Fixture failed = new Fixture(); final SafReceiveTransaction.Record failedSnapshot = failed.candidate();
        failed.failSave = true; fails(() -> failed.transactions.confirmPublicationReconcile(failedSnapshot));
        check(failed.record.state == SafReceiveTransaction.State.PUBLISHING); check(!failed.record.receiveReleased); failed.untouched();
        for (long size : new long[] {0, 42, Long.MAX_VALUE}) {
            Fixture f = new Fixture(); f.record.size = size;
            SafReceiveTransaction.Record original = f.candidate();
            SafReceiveTransaction.Record receipt = f.transactions.confirmPublicationReconcile(original);
            check(receipt.state == SafReceiveTransaction.State.PUBLISHED && receipt.receiveReleased);
            check(Objects.equals(receipt.lease, original.lease)); check(receipt.size == size);
            check(receipt.output == original.output && receipt.cache == original.cache && receipt.staging == original.staging);
            check(receipt.recoveryCompleted && Objects.equals(receipt.recoverySourceId, original.recoverySourceId));
            check(f.candidate() == null); check(f.saves == 1);
            fails(() -> f.transactions.confirmPublicationReconcile(original));
            fails(() -> f.transactions.openReceive(receipt.id, receipt.sessionId, receipt.fileId, receipt.attemptId));
            f.untouched();
        }
        Fixture invalid = new Fixture(); fails(() -> invalid.transactions.publicationReconcileCandidate("../bad"));
        check(invalid.transactions.publicationReconcileCandidate(UUID.randomUUID().toString()) == null);
        System.out.println("SAF publication reconciliation: " + checks + " assertions passed (host state machine, not device acceptance)");
    }
}
