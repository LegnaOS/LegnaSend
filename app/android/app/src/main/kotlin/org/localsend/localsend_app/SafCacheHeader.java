package org.localsend.localsend_app;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/** Bounded reader for the shared .ls v1 header, not proof of payload or document ownership. */
public final class SafCacheHeader {
    private static final byte[] MAGIC = new byte[] {76, 69, 71, 78, 65, 76, 83, 0};
    private static final int HEADER_LIMIT = 16 * 1024;

    /**
     * Reads exactly the binary header, JSON and SHA-256, leaving payload unread.
     * The caller retains stream ownership and must parse JSON and bind transaction,
     * size and provider identity separately. This method does not close the stream.
     */
    public static String read(InputStream input) throws IOException {
        byte[] header = readExactly(input, 16);
        if (!Arrays.equals(Arrays.copyOf(header, MAGIC.length), MAGIC)) throw new IOException("Unknown receive cache format");
        ByteBuffer numbers = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
        if (numbers.getInt(8) != 1) throw new IOException("Unknown receive cache version");
        int length = numbers.getInt(12);
        if (length <= 0 || length > HEADER_LIMIT) throw new IOException("Invalid receive cache header length");
        byte[] json = readExactly(input, length);
        byte[] expected = readExactly(input, 32);
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update(header); digest.update(json);
            if (!MessageDigest.isEqual(expected, digest.digest())) throw new IOException("Receive cache header checksum differs");
        } catch (NoSuchAlgorithmException impossible) { throw new IOException("SHA-256 is unavailable", impossible); }
        try {
            return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(json)).toString();
        } catch (CharacterCodingException invalid) { throw new IOException("Invalid receive cache UTF-8", invalid); }
    }

    private static byte[] readExactly(InputStream input, int length) throws IOException {
        byte[] bytes = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(bytes, offset, length - offset);
            if (count < 0) throw new EOFException("Receive cache header is incomplete");
            if (count == 0) {
                int next = input.read();
                if (next < 0) throw new EOFException("Receive cache header is incomplete");
                bytes[offset++] = (byte) next;
            } else offset += count;
        }
        return bytes;
    }
    private SafCacheHeader() {}
}
