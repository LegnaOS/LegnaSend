package org.localsend.localsend_app;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Atomic, bounded metadata selection; a missing provider length is never an empty file. */
final class SafFileSelection {
    static final int MAX_FILES = 20000, MAX_BYTES = 16 * 1024 * 1024;
    static final class File {
        final String uri, name;
        final long size;
        final Long modified;
        File(String uri, String name, long size, Long modified) {
            this.uri = uri; this.name = name; this.size = size; this.modified = modified;
        }
    }
    interface Provider {
        void check() throws Exception;
        void persistRead(String uri) throws Exception;
        SafFolderTree.Node query(String uri) throws Exception;
    }
    interface ReadGrant {
        boolean persisted();
        void acquire() throws Exception;
    }
    static void ensurePersistentRead(ReadGrant grant, boolean readOffered, boolean persistOffered) throws Exception {
        // Re-selecting a previously authorized URI need not offer a new grant.
        if (grant.persisted()) return;
        if (!readOffered || !persistOffered) throw new SecurityException("Persistent read access was not granted");
        grant.acquire();
        if (!grant.persisted()) throw new SecurityException("Persistent read access was not retained");
    }
    static List<File> read(Provider provider, List<String> uris) throws Exception {
        provider.check();
        if (uris == null || uris.isEmpty()) throw new SafFolderTree.Failure("invalid");
        if (uris.size() > MAX_FILES) throw new SafFolderTree.Failure("limit");
        List<File> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        long bytes = 0;
        for (String uri : uris) {
            provider.check();
            if (uri == null || uri.isEmpty() || uri.length() > 16384) throw new SafFolderTree.Failure("invalid");
            if (!seen.add(uri)) continue;
            provider.persistRead(uri);
            provider.check();
            SafFolderTree.Node node = provider.query(uri);
            if (node == null) throw new SafFolderTree.Failure("unavailable");
            if (!uri.equals(node.uri)) throw new SafFolderTree.Failure("invalid");
            String name = SafFolderTree.name(node.name);
            if (node.directory || node.virtual || node.size == null || node.size < 0 || node.size > 9007199254740991L)
                throw new SafFolderTree.Failure("unsupported");
            bytes += 256L + 4L * (uri.length() + name.length());
            if (bytes > MAX_BYTES) throw new SafFolderTree.Failure("limit");
            result.add(new File(uri, name, node.size, node.modified != null && node.modified > 0 ? node.modified : null));
        }
        provider.check();
        return result;
    }
}
