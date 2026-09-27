package org.localsend.localsend_app;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Locale;

public final class SafVerifiedCopyTest {
    private static int assertions;
    private static void check(boolean value) { assertions++; if (!value) throw new AssertionError(); }
    private interface Attempt { void run() throws IOException; }
    private static IOException fails(Attempt action) {
        try { action.run(); throw new AssertionError("Expected copy failure"); }
        catch (IOException expected) { assertions++; return expected; }
    }
    private static String sha(byte[] bytes) throws Exception {
        StringBuilder value = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) value.append(String.format(Locale.ROOT, "%02x", b & 255));
        return value.toString();
    }
    private static final class Source implements SafVerifiedCopy.Reader {
        final byte[] bytes; final int maximum;
        int position, calls, maxRequested; byte[] firstBuffer; boolean sameBuffer = true;
        Source(byte[] bytes, int maximum) { this.bytes = bytes; this.maximum = maximum; }
        @Override public int read(byte[] buffer, int offset, int length) {
            calls++; maxRequested = Math.max(maxRequested, length);
            if (firstBuffer == null) firstBuffer = buffer; else sameBuffer &= firstBuffer == buffer;
            int count = Math.min(Math.min(length, maximum), bytes.length - position);
            System.arraycopy(bytes, position, buffer, offset, count); position += count;
            return count;
        }
    }
    public static void main(String[] args) throws Exception {
        byte[] bytes = new byte[2 * 1024 * 1024 + 111];
        for (int index = 0; index < bytes.length; index++) bytes[index] = (byte) (index * 19 + 7);
        Source source = new Source(bytes, 7919);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        long copied = SafVerifiedCopy.copy(source, (buffer, offset, length) -> {
            int count = Math.min(length, 1009); output.write(buffer, offset, count); return count;
        }, bytes.length, sha(bytes).toUpperCase(Locale.ROOT));
        check(copied == bytes.length);
        check(Arrays.equals(output.toByteArray(), bytes));
        check(source.position == bytes.length);
        check(source.calls > bytes.length / 7919);
        check(source.maxRequested == 64 * 1024);
        check(source.sameBuffer);

        int[] calls = {0, 0};
        check(SafVerifiedCopy.copy((buffer, offset, length) -> { calls[0]++; return 0; },
            (buffer, offset, length) -> { calls[1]++; return length; }, 0, sha(new byte[0])) == 0);
        check(calls[0] == 1 && calls[1] == 0);

        String identity = sha(bytes);
        check(fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> length,
            bytes.length + 1, identity)) instanceof SafVerifiedCopy.Mismatch);
        check(fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> length,
            bytes.length - 1, identity)) instanceof SafVerifiedCopy.Mismatch);
        check(fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> length,
            bytes.length, "0".repeat(64))) instanceof SafVerifiedCopy.Mismatch);
        check(fails(() -> SafVerifiedCopy.copy(new Source(new byte[0], 1), (buffer, offset, length) -> length,
            Long.MAX_VALUE, identity)) instanceof SafVerifiedCopy.Mismatch);

        IOException readError = new IOException("read failed");
        check(fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> { throw readError; },
            (buffer, offset, length) -> length, bytes.length, identity)) == readError);
        IOException writeError = new IOException("write failed");
        check(fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536),
            (buffer, offset, length) -> { throw writeError; }, bytes.length, identity)) == writeError);
        fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> 0, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> -1, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy(new Source(bytes, 65536), (buffer, offset, length) -> length + 1, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> -1, (buffer, offset, length) -> length, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> length + 1, (buffer, offset, length) -> length, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy(null, (buffer, offset, length) -> length, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy(source, null, bytes.length, identity));
        fails(() -> SafVerifiedCopy.copy(source, (buffer, offset, length) -> length, -1, identity));
        fails(() -> SafVerifiedCopy.copy(source, (buffer, offset, length) -> length, 0, null));
        fails(() -> SafVerifiedCopy.copy(source, (buffer, offset, length) -> length, 0, "x".repeat(64)));
        System.out.println("SAF verified bounded copy: " + assertions + " assertions passed");
    }
}
