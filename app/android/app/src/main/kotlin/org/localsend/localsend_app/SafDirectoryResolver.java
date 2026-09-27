package org.localsend.localsend_app;

import java.io.IOException;
import java.util.List;

/** Provider-neutral traversal. Document IDs are opaque, never path fragments. */
public final class SafDirectoryResolver {
    public static final class Failure extends IOException {
        public final String code;
        public Failure(String code, String message) { super(message); this.code = code; }
    }
    public static final class Document {
        public final String uri;
        public final String name;
        public final boolean directory;
        public final boolean canCreate;
        public Document(String uri, String name, boolean directory, boolean canCreate) {
            this.uri = uri; this.name = name; this.directory = directory; this.canCreate = canCreate;
        }
    }
    public interface Backend {
        /** Checks the persisted read/write grant on every invocation. */
        String writableRoot(String tree) throws IOException;
        Document stat(String uri) throws IOException;
        /** Returns null if absent; rejects ambiguous names and failed queries. */
        Document findChild(String parent, String name) throws IOException;
        String createDirectory(String parent, String name) throws IOException;
    }
    public static String resolve(Backend backend, String tree, List<String> components) throws IOException {
        if (tree == null || components == null || components.size() > 128) {
            throw new Failure("INVALID_ARGUMENT", "Invalid destination directory");
        }
        // Validate the whole path before making any mutation.
        for (String name : components) validateName(name);
        String current = backend.writableRoot(tree);
        requireDirectory(backend.stat(current), null);
        for (String name : components) {
            Document child = backend.findChild(current, name);
            if (child == null) {
                String created = backend.createDirectory(current, name);
                if (created == null) throw new Failure("CREATE_FAILED", "Provider did not create a directory");
                child = backend.stat(created);
            }
            requireDirectory(child, name);
            current = child.uri;
        }
        return current;
    }
    public static void requireCompleteListing(boolean loading, boolean hasError) throws Failure {
        if (loading || hasError) throw new Failure("DIRECTORY_UNAVAILABLE", "Provider directory listing is incomplete");
    }
    public static void validateName(String name) throws Failure {
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..")
                || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
            throw new Failure("INVALID_ARGUMENT", "Invalid directory component");
        }
        for (int i = 0; i < name.length(); i++) {
            if (Character.isISOControl(name.charAt(i))) throw new Failure("INVALID_ARGUMENT", "Invalid directory component");
        }
    }
    private static void requireDirectory(Document document, String name) throws Failure {
        if (document == null) throw new Failure("DIRECTORY_UNAVAILABLE", "Destination no longer exists");
        if (!document.directory || (name != null && !name.equals(document.name))) {
            throw new Failure("NAME_CONFLICT", "Destination name is not the requested directory");
        }
        if (!document.canCreate) throw new Failure("PERMISSION_DENIED", "Destination is not writable");
    }
    private SafDirectoryResolver() {}
}
