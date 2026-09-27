package org.localsend.localsend_app;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.OperationCanceledException;
import android.provider.DocumentsContract;
import io.flutter.plugin.common.MethodChannel;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Provider calls never run on the UI thread; cancelled blocked calls still occupy bounded workers. */
final class AndroidFileSelection {
    private static final ThreadPoolExecutor WORK = new ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(2));
    private static final String[] COLUMNS = {
        DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_FLAGS
    };
    private final ContentResolver resolver;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<CancellationSignal> signals = ConcurrentHashMap.newKeySet();
    private volatile boolean closed;
    AndroidFileSelection(Context context) { resolver = context.getApplicationContext().getContentResolver(); }
    void close() { closed = true; for (CancellationSignal signal : signals) signal.cancel(); }
    void read(List<String> uris, int grantFlags, MethodChannel.Result reply) {
        CancellationSignal signal = new CancellationSignal();
        signals.add(signal);
        try {
            WORK.execute(() -> {
                List<Map<String, Object>> value = null;
                String error = null;
                try {
                    List<SafFileSelection.File> files = SafFileSelection.read(new SafFileSelection.Provider() {
                        public void check() {
                            if (closed || signal.isCanceled()) throw new OperationCanceledException();
                        }
                        public void persistRead(String value) throws Exception {
                            Uri uri = Uri.parse(value);
                            if (!ContentResolver.SCHEME_CONTENT.equals(uri.getScheme()) || uri.getAuthority() == null
                                    || uri.getAuthority().isEmpty()) throw new SafFolderTree.Failure("invalid");
                            // Sending never needs a durable write grant, even when the picker offers one.
                            SafFileSelection.ensurePersistentRead(new SafFileSelection.ReadGrant() {
                                public boolean persisted() {
                                    for (android.content.UriPermission permission : resolver.getPersistedUriPermissions()) {
                                        if (permission.isReadPermission() && uri.equals(permission.getUri())) return true;
                                    }
                                    return false;
                                }
                                public void acquire() {
                                    resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                }
                            }, (grantFlags & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0,
                                (grantFlags & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0);
                        }
                        public SafFolderTree.Node query(String value) throws Exception {
                            try (Cursor cursor = resolver.query(Uri.parse(value), COLUMNS, null, null, null, signal)) {
                                if (cursor == null) throw new SafFolderTree.Failure("unavailable");
                                complete(cursor);
                                if (!cursor.moveToFirst()) throw new SafFolderTree.Failure("unavailable");
                                String name = cursor.getString(0), mime = cursor.getString(3);
                                if (mime == null || mime.isEmpty()) throw new SafFolderTree.Failure("unsupported");
                                SafFolderTree.Node node = new SafFolderTree.Node(value, name, value,
                                    DocumentsContract.Document.MIME_TYPE_DIR.equals(mime),
                                    !cursor.isNull(4) && (cursor.getLong(4) & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0,
                                    cursor.isNull(1) ? null : cursor.getLong(1), cursor.isNull(2) ? null : cursor.getLong(2));
                                if (cursor.moveToNext()) throw new SafFolderTree.Failure("invalid");
                                complete(cursor);
                                return node;
                            }
                        }
                    }, uris);
                    SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT);
                    format.setTimeZone(TimeZone.getTimeZone("UTC"));
                    value = new ArrayList<>();
                    for (SafFileSelection.File file : files) {
                        Map<String, Object> item = new HashMap<>();
                        item.put("uri", file.uri); item.put("name", file.name); item.put("size", file.size);
                        item.put("lastModified", file.modified == null ? null : format.format(new Date(file.modified)));
                        value.add(item);
                    }
                } catch (SecurityException e) { error = "permission"; }
                  catch (OperationCanceledException e) { error = "cancelled"; }
                  catch (SafFolderTree.Failure e) { error = e.code; }
                  catch (Exception e) { error = "unavailable"; }
                finally { signals.remove(signal); }
                final List<Map<String, Object>> completed = value;
                final String failure = error;
                main.post(() -> {
                    if (closed || signal.isCanceled()) reply.error("cancelled", "cancelled", null);
                    else if (failure != null) reply.error(failure, failure, null);
                    else reply.success(completed);
                });
            });
        } catch (RejectedExecutionException e) { signals.remove(signal); reply.error("busy", "busy", null); }
    }
    private static void complete(Cursor cursor) throws Exception {
        if (cursor.getExtras() == null) return;
        if (cursor.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING, false)) throw new SafFolderTree.Failure("loading");
        if (cursor.getExtras().containsKey(DocumentsContract.EXTRA_ERROR)) throw new SafFolderTree.Failure("unavailable");
    }
}
