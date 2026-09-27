package org.localsend.localsend_app;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Random;

/** Independent host tests for the bounded copy/hash loop, not provider acceptance. */
public final class SafVerifiedCopyAdversarialTest {
    private static int checks;
    private static void truth(boolean value) { checks++; if (!value) throw new AssertionError(); }
    private static String digest(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }
    private interface Work { void run() throws Exception; }
    private static void fails(Work work) throws Exception {
        try { work.run(); throw new AssertionError("Expected IOException"); }
        catch (IOException expected) { checks++; }
    }
    private static final class Source implements SafVerifiedCopy.Reader {
        final byte[] bytes;
        final int fragment;
        int cursor, reads, maxRequest;
        Source(byte[] bytes, int fragment) { this.bytes = bytes; this.fragment = fragment; }
        @Override public int read(byte[] buffer, int offset, int length) {
            reads++; maxRequest = Math.max(maxRequest, length);
            int count = Math.min(Math.min(length, fragment), bytes.length - cursor);
            System.arraycopy(bytes, cursor, buffer, offset, count); cursor += count;
            return count;
        }
    }
    private static final class Destination implements SafVerifiedCopy.Writer {
        final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        final int fragment;
        int writes, maxRequest;
        Destination(int fragment) { this.fragment = fragment; }
        @Override public int write(byte[] buffer, int offset, int length) {
            writes++; maxRequest = Math.max(maxRequest, length);
            int count = Math.min(length, fragment);
            bytes.write(buffer, offset, count); return count;
        }
    }
    public static void main(String[] args) throws Exception {
        // Irregular provider short reads/writes must preserve every byte and hash once per source byte.
        int[][] fragmentation = {{1, 1}, {7, 3}, {65536, 13}, {65535, 65536}, {Integer.MAX_VALUE, Integer.MAX_VALUE}};
        for (int[] fragments : fragmentation) {
            byte[] input = new byte[131079]; new Random(17).nextBytes(input);
            Source source = new Source(input, fragments[0]); Destination target = new Destination(fragments[1]);
            long count = SafVerifiedCopy.copy(source, target, input.length, digest(input));
            truth(count == input.length); truth(Arrays.equals(target.bytes.toByteArray(), input));
            truth(source.maxRequest <= 65536); truth(target.maxRequest <= 65536);
            truth(source.reads > 1); truth(target.writes > 1);
        }
        byte[] empty = new byte[0]; Source zero = new Source(empty, 1); Destination untouched = new Destination(1);
        truth(SafVerifiedCopy.copy(zero, untouched, 0, digest(empty)) == 0); truth(untouched.writes == 0);

        byte[] expected = new byte[1003]; new Random(22).nextBytes(expected);
        // An explicit EOF before declared length and any extra byte both fail; no padding/truncation.
        fails(() -> SafVerifiedCopy.copy(new Source(Arrays.copyOf(expected, 1002), 31), new Destination(17), 1003, digest(expected)));
        Destination excess = new Destination(5);
        fails(() -> SafVerifiedCopy.copy(new Source(Arrays.copyOf(expected, 1004), 37), excess, 1003, digest(expected)));
        truth(excess.bytes.size() <= 1003);
        fails(() -> SafVerifiedCopy.copy(new Source(new byte[] {1}, 1), new Destination(1), 0, digest(empty)));

        byte[] mutated = expected.clone(); mutated[mutated.length / 2] ^= 0x20;
        fails(() -> SafVerifiedCopy.copy(new Source(mutated, 47), new Destination(23), expected.length, digest(expected)));
        // Broken providers must fail promptly rather than spin or accept impossible byte counts.
        fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> -1, new Destination(1), 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> length + 1, new Destination(1), 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy(new Source(new byte[] {1}, 1), (buffer, offset, length) -> 0, 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy(new Source(new byte[] {1}, 1), (buffer, offset, length) -> -1, 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy(new Source(new byte[] {1}, 1), (buffer, offset, length) -> length + 1, 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy((buffer, offset, length) -> { throw new IOException("Provider read fault"); }, new Destination(1), 1, digest(new byte[] {1})));
        fails(() -> SafVerifiedCopy.copy(new Source(expected, 19), (buffer, offset, length) -> { throw new IOException("Provider write fault"); }, expected.length, digest(expected)));

        Destination interrupted = new Destination(11);
        fails(() -> SafVerifiedCopy.copy(new Source(expected, 37), (buffer, offset, length) -> {
            if (interrupted.bytes.size() >= 50) throw new IOException("Storage removed during partial write");
            return interrupted.write(buffer, offset, length);
        }, expected.length, digest(expected)));
        truth(interrupted.bytes.size() > 0 && interrupted.bytes.size() < expected.length);
        // Length arithmetic must not narrow the declared size to 32 bits.
        fails(() -> SafVerifiedCopy.copy(new Source(empty, 1), new Destination(1), (long) Integer.MAX_VALUE + 1, digest(empty)));
        fails(() -> SafVerifiedCopy.copy(new Source(empty, 1), new Destination(1), Long.MAX_VALUE, digest(empty)));
        fails(() -> SafVerifiedCopy.copy(new Source(empty, 1), new Destination(1), -1, digest(empty)));
        ioAccounting();
        smallFileWorkload();
        System.out.println("SAF verified copy adversarial: " + checks + " assertions passed");
    }
    private static long verifyRead(Source source, String expected) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[65536]; long bytes = 0;
        while (true) {
            int count = source.read(buffer, 0, buffer.length);
            if (count == 0) break;
            hash.update(buffer, 0, count); bytes += count;
        }
        truth(HexFormat.of().formatHex(hash.digest()).equals(expected));
        return bytes;
    }
    private static void ioAccounting() throws Exception {
        byte[] input = new byte[1048613]; new Random(123).nextBytes(input); String hash = digest(input);
        long preflight = verifyRead(new Source(input, 8191), hash);
        Source copySource = new Source(input, 4093); Destination target = new Destination(997);
        truth(SafVerifiedCopy.copy(copySource, target, input.length, hash) == input.length);
        // This models the mandatory independent reopen/read-back, not a provider durability claim.
        long postCloseRead = verifyRead(new Source(target.bytes.toByteArray(), 12289), hash);
        // Previous code made this additional full destination pass before close.
        long redundantPreCloseRead = verifyRead(new Source(target.bytes.toByteArray(), 16381), hash);
        long optimizedReads = preflight + copySource.cursor + postCloseRead;
        long previousReads = optimizedReads + redundantPreCloseRead;
        truth(optimizedReads == 3L * input.length);
        truth(previousReads == 4L * input.length);
        truth(previousReads - optimizedReads == input.length);
        truth(postCloseRead == input.length); truth(target.bytes.size() == input.length);
        System.out.println("Synthetic publication accounting: previous read bytes=" + previousReads
            + ", optimized=" + optimizedReads + ", removed=" + redundantPreCloseRead
            + "; post-close verification retained; not provider throughput");
    }
    private static void smallFileWorkload() throws Exception {
        byte[] input = new byte[1024]; new Random(58).nextBytes(input);
        long bytes = 0;
        for (int i = 0; i < 5000; i++) {
            input[0] = (byte) i; input[1] = (byte) (i >>> 8);
            Source source = new Source(input, 127); Destination target = new Destination(61);
            bytes += SafVerifiedCopy.copy(source, target, input.length, digest(input));
            if (!Arrays.equals(input, target.bytes.toByteArray())) throw new AssertionError("Small-file output differs at " + i);
        }
        truth(bytes == 5000L * input.length);
        System.out.println("Synthetic copy workload: 5000 x 1024-byte files verified; no SAF, disk, network or timing claim");
    }

}
