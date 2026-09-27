package org.localsend.localsend_app;

/** Short state transitions only: provider I/O never runs under this monitor. */
final class SafWorkspaceWriteGate {
    enum Phase { PREPARING, RECEIVING, COMMITTING, PUBLISHED, UNCONFIRMED, CANCELLED, RELEASED }
    private Phase phase = Phase.PREPARING;
    synchronized Phase phase() { return phase; }
    synchronized boolean ready() { if (phase != Phase.PREPARING) return false; phase = Phase.RECEIVING; return true; }
    synchronized boolean commit() { if (phase != Phase.RECEIVING) return false; phase = Phase.COMMITTING; return true; }
    synchronized boolean cancel() {
        if (phase == Phase.COMMITTING || phase == Phase.PUBLISHED || phase == Phase.UNCONFIRMED) return false;
        if (phase != Phase.RELEASED) phase = Phase.CANCELLED;
        return true;
    }
    synchronized void published() { if (phase != Phase.COMMITTING) throw new IllegalStateException(); phase = Phase.PUBLISHED; }
    synchronized void uncertain() { if (phase == Phase.COMMITTING) phase = Phase.UNCONFIRMED; }
    synchronized void failed() { if (phase == Phase.COMMITTING) phase = Phase.CANCELLED; }
    synchronized void released() { if (phase != Phase.COMMITTING) phase = Phase.RELEASED; }
}
