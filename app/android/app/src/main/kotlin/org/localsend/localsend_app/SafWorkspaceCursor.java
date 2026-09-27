package org.localsend.localsend_app;

import java.util.UUID;

/** Cursor positions are part of their identity: replay never silently advances another page. */
public final class SafWorkspaceCursor {
    public final String id;
    public final long offset;
    private SafWorkspaceCursor(String id, long offset) { this.id = id; this.offset = offset; }
    public static SafWorkspaceCursor parse(String value) {
        int separator = value.lastIndexOf(':');
        if (separator < 0) throw new IllegalArgumentException("Invalid cursor");
        String id = value.substring(0, separator);
        if (!UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException("Invalid cursor");
        String rawOffset = value.substring(separator + 1);
        long offset = Long.parseLong(rawOffset);
        if (offset < 0 || !Long.toString(offset).equals(rawOffset)) throw new IllegalArgumentException("Invalid cursor");
        return new SafWorkspaceCursor(id, offset);
    }
    public boolean matches(long currentOffset) { return offset == currentOffset; }
    public static String encode(String id, long offset) { return id + ":" + offset; }
}
