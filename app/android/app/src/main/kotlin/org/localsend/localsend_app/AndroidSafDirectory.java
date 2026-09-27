package org.localsend.localsend_app;

import android.content.ContentResolver;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.DocumentsContract;
import java.io.IOException;
import java.util.List;

/** Resolves only real provider IDs inside a persisted writable tree grant. */
public final class AndroidSafDirectory implements SafDirectoryResolver.Backend {
    private static final String[] COLUMNS = {
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_FLAGS
    };
    private final ContentResolver resolver;
    public AndroidSafDirectory(ContentResolver resolver) { this.resolver = resolver; }

    public String resolve(String tree, List<String> components) throws IOException {
        return SafDirectoryResolver.resolve(this, tree, components);
    }
    @Override public String writableRoot(String value) throws IOException {
        Uri tree = Uri.parse(value);
        if (!ContentResolver.SCHEME_CONTENT.equals(tree.getScheme()) || tree.getAuthority() == null
                || tree.getAuthority().isEmpty() || tree.getQuery() != null || tree.getFragment() != null
                || !DocumentsContract.isTreeUri(tree)) {
            throw new SafDirectoryResolver.Failure("INVALID_ARGUMENT", "Expected a document tree");
        }
        String rootId = DocumentsContract.getTreeDocumentId(tree);
        // A stored nested document URI must not silently resolve to its tree root.
        List<String> segments = tree.getPathSegments();
        if (segments.size() != 2 || !"tree".equals(segments.get(0))) {
            throw new SafDirectoryResolver.Failure("INVALID_ARGUMENT", "Expected the selected tree URI");
        }
        boolean granted = false;
        for (UriPermission permission : resolver.getPersistedUriPermissions()) {
            Uri uri = permission.getUri();
            if (permission.isReadPermission() && permission.isWritePermission()
                    && DocumentsContract.isTreeUri(uri) && tree.getAuthority().equals(uri.getAuthority())
                    && rootId.equals(DocumentsContract.getTreeDocumentId(uri))) {
                granted = true;
                break;
            }
        }
        if (!granted) throw new SafDirectoryResolver.Failure("PERMISSION_DENIED", "Select the download directory again to grant access");
        return DocumentsContract.buildDocumentUriUsingTree(tree, rootId).toString();
    }
    @Override public SafDirectoryResolver.Document stat(String value) throws IOException {
        Uri uri = Uri.parse(value);
        try (Cursor cursor = resolver.query(uri, COLUMNS, null, null, null)) {
            if (cursor == null) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Provider query failed");
            requireComplete(cursor);
            if (!cursor.moveToNext()) return null;
            SafDirectoryResolver.Document result = read(uri, cursor);
            if (cursor.moveToNext()) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Ambiguous document identity");
            if (!DocumentsContract.getDocumentId(uri).equals(DocumentsContract.getDocumentId(Uri.parse(result.uri)))) {
                throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Document identity changed");
            }
            return result;
        }
    }
    @Override public SafDirectoryResolver.Document findChild(String parent, String name) throws IOException {
        Uri uri = Uri.parse(parent);
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getDocumentId(uri));
        try (Cursor cursor = resolver.query(children, COLUMNS, null, null, null)) {
            if (cursor == null) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Provider query failed");
            requireComplete(cursor);
            SafDirectoryResolver.Document found = null;
            int count = 0;
            while (cursor.moveToNext()) {
                if (++count > 100000) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Directory scan limit reached");
                if (name.equals(cursor.getString(1))) {
                    if (found != null) throw new SafDirectoryResolver.Failure("NAME_CONFLICT", "Multiple documents have the same name");
                    found = read(uri, cursor);
                }
            }
            requireComplete(cursor);
            return found;
        }
    }
    @Override public String createDirectory(String parent, String name) throws IOException {
        Uri uri = DocumentsContract.createDocument(resolver, Uri.parse(parent), DocumentsContract.Document.MIME_TYPE_DIR, name);
        if (uri == null) return null;
        Uri original = Uri.parse(parent);
        if (!original.getAuthority().equals(uri.getAuthority()) || !DocumentsContract.isTreeUri(uri)
                || !DocumentsContract.getTreeDocumentId(original).equals(DocumentsContract.getTreeDocumentId(uri))) {
            throw new SafDirectoryResolver.Failure("CREATE_FAILED", "Provider returned a different document tree");
        }
        return uri.toString();
    }
    private static void requireComplete(Cursor cursor) throws IOException {
        Bundle extras = cursor.getExtras();
        SafDirectoryResolver.requireCompleteListing(
            extras != null && extras.getBoolean(DocumentsContract.EXTRA_LOADING, false),
            extras != null && extras.containsKey(DocumentsContract.EXTRA_ERROR)
        );
    }
    private SafDirectoryResolver.Document read(Uri tree, Cursor cursor) throws IOException {
        String id = cursor.getString(0);
        if (id == null || id.isEmpty()) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "Provider returned no document ID");
        return new SafDirectoryResolver.Document(
            DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(), cursor.getString(1),
            DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2)),
            (cursor.getLong(3) & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0
        );
    }
}
