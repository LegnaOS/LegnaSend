package org.localsend.localsend_app;

import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Bounded copy with source hashing. Callers retain ownership, sync, close and
 * independently reopen/verify the provider-visible destination before success. */
public final class SafVerifiedCopy {
    public static final int BUFFER_SIZE = 64 * 1024;
    private SafVerifiedCopy() { }
    @FunctionalInterface public interface Reader {
        /** POSIX semantics: zero is explicit EOF; negative counts are invalid. */
        int read(byte[] buffer, int offset, int length) throws IOException;
    }
    @FunctionalInterface public interface Writer {
        /** Positive partial writes are valid; zero/negative progress is an error. */
        int write(byte[] buffer, int offset, int length) throws IOException;
    }
    public static final class Mismatch extends IOException {
        private static final long serialVersionUID = 1L;
        public Mismatch(String message) { super(message); }
    }
    public static long copy(Reader reader, Writer writer, long expectedSize, String expectedSha256) throws IOException {
        if (reader == null || writer == null || expectedSize < 0 || expectedSha256 == null
                || !expectedSha256.matches("[a-fA-F0-9]{64}")) throw new IOException("Invalid verified copy identity");
        final MessageDigest hash;
        try { hash = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException error) { throw new IOException("SHA-256 is unavailable", error); }
        byte[] buffer = new byte[BUFFER_SIZE];
        long total = 0;
        while (true) {
            int count = reader.read(buffer, 0, buffer.length);
            if (count == 0) break;
            if (count < 0 || count > buffer.length) throw new IOException("Invalid provider read count");
            if (count > expectedSize - total) throw new Mismatch("Staging exceeds the verified size");
            hash.update(buffer, 0, count);
            int offset = 0;
            while (offset < count) {
                int written = writer.write(buffer, offset, count - offset);
                if (written <= 0 || written > count - offset) throw new IOException("Provider made invalid write progress");
                offset += written;
            }
            total += count;
        }
        if (total != expectedSize) throw new Mismatch("Staging ended before the verified size");
        byte[] digest = hash.digest();
        StringBuilder actual = new StringBuilder(64);
        for (byte value : digest) {
            actual.append(Character.forDigit((value >>> 4) & 15, 16));
            actual.append(Character.forDigit(value & 15, 16));
        }
        if (!actual.toString().equalsIgnoreCase(expectedSha256)) throw new Mismatch("Staging changed after validation");
        return total;
    }
}
