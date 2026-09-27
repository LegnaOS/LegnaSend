package org.localsend.localsend_app;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Host test of the production worker ownership boundary, not an Android provider/device test. */
public final class SafWorkspaceWorkTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        String cursorId = "ff4df9b0-9e9a-4dda-a3de-91d9fc4b74ca";
        SafWorkspaceCursor first = SafWorkspaceCursor.parse(SafWorkspaceCursor.encode(cursorId, 100));
        require(first.matches(100)); require(!first.matches(200));
        require(SafWorkspaceCursor.parse(SafWorkspaceCursor.encode(cursorId, 200)).matches(200));
        for (String bad : new String[] {cursorId + ":-1", cursorId + ":0100", cursorId + ":+1", cursorId, "arbitrary:0"}) {
            try { SafWorkspaceCursor.parse(bad); throw new AssertionError("Accepted invalid cursor"); }
            catch (IllegalArgumentException expected) {}
        }
        SafWorkspaceReferenceBudget refs = new SafWorkspaceReferenceBudget(2, 100);
        require(refs.replace(1, 30)); require(refs.replace(1, 60));
        require(!refs.replace(1, 1)); require(!refs.replace(0, 11));
        require(refs.count() == 2 && refs.bytes() == 90);
        require(refs.replace(0, -20)); require(refs.replace(-2, -70));
        require(refs.count() == 0 && refs.bytes() == 0);
        require(refs.replace(1, 100)); require(refs.replace(-1, -100));
        SafWorkspaceWork work = new SafWorkspaceWork(2);
        CountDownLatch entered = new CountDownLatch(2), release = new CountDownLatch(1), cleaned = new CountDownLatch(2);
        AtomicInteger canceled = new AtomicInteger(), lateClosed = new AtomicInteger();
        for (int i = 0; i < 2; i++) {
            require(work.submit("request-" + i, 1, canceled::incrementAndGet, ticket -> {
                entered.countDown();
                try { release.await(); } catch (InterruptedException e) { throw new AssertionError(e); }
                if (ticket.cancelled()) lateClosed.incrementAndGet();
                cleaned.countDown();
            }));
        }
        require(entered.await(2, TimeUnit.SECONDS));
        work.cancel("request-0", 2); require(canceled.get() == 0); // Wrong Activity never cancels a current owner.
        work.cancel("request-0", 1); work.cancel("request-0", 1); require(canceled.get() == 1);
        require(work.activeCount() == 2);
        require(!work.submit("third", 1, () -> {}, ticket -> {})); // Cancellation does not free the syscall slot.
        require(!work.submit("request-0", 1, () -> {}, ticket -> {})); // Nor can its ID be reused early.
        work.cancelOwner(1); require(canceled.get() == 2);
        release.countDown(); require(cleaned.await(2, TimeUnit.SECONDS));
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (work.activeCount() != 0 && System.nanoTime() < end) Thread.yield();
        require(work.activeCount() == 0); require(lateClosed.get() == 2);
        CountDownLatch next = new CountDownLatch(1);
        require(work.submit("fresh", 2, () -> {}, ticket -> next.countDown()));
        require(next.await(2, TimeUnit.SECONDS)); work.shutdownForTest();
        System.out.println("PASS: exact cursor replay position; global reference budget/replacement/close; canceled blocked workers retain budget; exact owner/id; late cleanup; next operation");
    }
}
