package org.localsend.localsend_app;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Objects;

/** Reads a container made by real Rust DownloadCache::create, then injects faults. */
public final class SafCacheHeaderTest {
    private static int checks;
    private static void eq(Object a, Object b) { checks++; if (!Objects.equals(a, b)) throw new AssertionError(a + " != " + b); }
    private static void invalid(byte[] bytes) throws IOException {
        try { SafCacheHeader.read(new ByteArrayInputStream(bytes)); throw new AssertionError("Malformed header accepted"); }
        catch (IOException expected) { checks++; }
    }
    private static byte[] sealed(byte[] json) throws Exception {
        byte[] header = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .put(new byte[] {76,69,71,78,65,76,83,0}).putInt(1).putInt(json.length).array();
        ByteArrayOutputStream out = new ByteArrayOutputStream(); out.write(header); out.write(json);
        MessageDigest digest = MessageDigest.getInstance("SHA-256"); digest.update(header); digest.update(json); out.write(digest.digest());
        return out.toByteArray();
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 0 && args.length != 2) throw new IllegalArgumentException("Provide both Rust cache and exact JSON fixture paths, or neither");
        boolean nativeFixture = args.length == 2;
        String expected = nativeFixture ? Files.readString(Path.of(args[1]), StandardCharsets.UTF_8) : "{\"fileName\":\"boundary fixture\"}";
        byte[] nativeCache = nativeFixture ? Files.readAllBytes(Path.of(args[0])) : sealed(expected.getBytes(StandardCharsets.UTF_8));
        ByteArrayInputStream stream = new ByteArrayInputStream(nativeCache);
        eq(SafCacheHeader.read(stream), expected);
        int jsonLength = ByteBuffer.wrap(nativeCache).order(ByteOrder.LITTLE_ENDIAN).getInt(12);
        int headerLength = 48 + jsonLength;
        eq(stream.available(), nativeCache.length - headerLength);
        if (nativeFixture && stream.available() <= 0) throw new AssertionError("Real Rust fixture must include committed payload records");
        // A one-byte stream must produce the identical header; no read assumes a complete buffer.
        InputStream fragmented = new FilterInputStream(new ByteArrayInputStream(nativeCache)) {
            @Override public int read(byte[] bytes, int offset, int length) throws IOException { return super.read(bytes, offset, Math.min(length, 1)); }
        };
        eq(SafCacheHeader.read(fragmented), expected);
        InputStream stalled = new FilterInputStream(new ByteArrayInputStream(nativeCache)) {
            boolean zero;
            @Override public int read(byte[] bytes, int offset, int length) throws IOException {
                zero = !zero; return zero ? 0 : super.read(bytes, offset, length);
            }
        };
        eq(SafCacheHeader.read(stalled), expected);
        for (int length = 0; length < headerLength; length++) invalid(Arrays.copyOf(nativeCache, length));
        for (int offset : new int[] {0, 7, 8, 11, 16, 16 + jsonLength - 1, 16 + jsonLength, headerLength - 1}) {
            byte[] corrupt = nativeCache.clone(); corrupt[offset] ^= 0x01; invalid(corrupt);
        }
        for (int length : new int[] {0, -1, 16385, Integer.MAX_VALUE, Integer.MIN_VALUE}) {
            byte[] corrupt = nativeCache.clone(); ByteBuffer.wrap(corrupt).order(ByteOrder.LITTLE_ENDIAN).putInt(12, length); invalid(corrupt);
        }
        invalid(sealed(new byte[] {(byte) 0xc0, (byte) 0xaf})); // Authenticated but invalid UTF-8.
        invalid(sealed(new byte[] {(byte) 0xe2, (byte) 0x82}));
        String unicode = "{\"fileName\":\"中文 % 😀\"}";
        eq(SafCacheHeader.read(new ByteArrayInputStream(sealed(unicode.getBytes(StandardCharsets.UTF_8)))), unicode);
        String max = " ".repeat(16384);
        eq(SafCacheHeader.read(new ByteArrayInputStream(sealed(max.getBytes(StandardCharsets.UTF_8)))), max);
        System.out.println((nativeFixture ? "SAF Rust cache header interoperability: " : "SAF cache header boundary tests (no native fixture): ") + checks + " assertions passed");
    }
    private SafCacheHeaderTest() {}
}
