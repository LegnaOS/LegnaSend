package org.localsend.localsend_app;

import android.content.ContentResolver;
import android.content.Context;
import android.content.UriPermission;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.provider.DocumentsContract;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.Closeable;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Read-only SAF workspace adapter. No document ID is ever interpreted as a filesystem path. */
public final class AndroidSafWorkspace {
    private static AndroidSafWorkspace instance;
    public static synchronized AndroidSafWorkspace get(Context context) {
        if (instance == null) instance = new AndroidSafWorkspace(context.getApplicationContext().getContentResolver());
        return instance;
    }
    private static final String[] COLUMNS = {
        DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_FLAGS, DocumentsContract.Document.COLUMN_LAST_MODIFIED
    };
    private static final int MAX_SCOPES = 64, MAX_REFS = 16384, MAX_CURSORS = 128;
    private static final long MAX_REF_BYTES = 16L * 1024 * 1024;
    private static final long CURSOR_TTL = 120000;
    private final ContentResolver resolver;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final SafWorkspaceWork work = new SafWorkspaceWork(8);
    private final ThreadPoolExecutor cancellation = new ThreadPoolExecutor(0, 8, 30, TimeUnit.SECONDS,
        new SynchronousQueue<>(), runnable -> { Thread t = new Thread(runnable, "LegnaSend-document-cancel"); t.setDaemon(true); return t; });
    private final Map<String, Scope> scopes = new HashMap<>();
    private final Map<String, Page> pages = new LinkedHashMap<>();
    private final Map<String, Watch> watches = new HashMap<>();
    private final SafWorkspaceWatchBudget watchBudget = new SafWorkspaceWatchBudget(64, 4, 30000);

    private volatile long owner;
    private final SafWorkspaceReferenceBudget references = new SafWorkspaceReferenceBudget(MAX_REFS, MAX_REF_BYTES);
    private final Map<String, Call> calls = new ConcurrentHashMap<>();
    private AndroidSafWorkspace(ContentResolver resolver) {
        this.resolver = resolver;
        main.postDelayed(new Runnable() {
            @Override public void run() { sweep(); main.postDelayed(this, 5000); }
        }, 5000);
    }
    public synchronized long attach() { long old = owner++; if (old != 0) detach(old); return owner; }
    public void detach(long value) {
        AndroidSafWorkspaceWrite.cancelScope(value, null);
        work.cancelOwner(value);
        synchronized (this) { for (Scope scope : scopes.values()) if (scope.owner == value) scope.closed = true; }
        sweep();
    }
    private static final class Failure extends Exception {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    private static final class Ref {
        final String id, name, mime;
        final boolean directory, virtual;
        final Long size, modified;
        final int depth;
        Ref(String id, String name, String mime, Long size, Long modified, boolean virtual, int depth) {
            this.id = id; this.name = name; this.mime = mime; this.size = size; this.modified = modified; this.virtual = virtual; this.depth = depth;
            directory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);
        }
        @Override public boolean equals(Object value) {
            if (!(value instanceof Ref)) return false;
            Ref other = (Ref) value;
            return id.equals(other.id) && name.equals(other.name) && mime.equals(other.mime)
                && Objects.equals(size, other.size) && Objects.equals(modified, other.modified)
                && virtual == other.virtual && depth == other.depth;
        }
        @Override public int hashCode() { return Objects.hash(id, name, mime, size, modified, virtual, depth); }
    }
    private static final class Scope {
        final String key;
        final Uri tree;
        final long owner;
        final Map<String, Ref> refs = new HashMap<>();
        final Map<String, String> tokens = new HashMap<>();
        volatile boolean closed;
        volatile long revision;
        volatile boolean initialized;
        final AtomicBoolean cleaning = new AtomicBoolean();
        long refBytes;
        Scope(String key, Uri tree, long owner) { this.key = key; this.tree = tree; this.owner = owner; }
    }
    private static final class Page {
        final String token = UUID.randomUUID().toString();
        final Scope scope;
        final Ref parent;
        final Cursor cursor;
        final long revision;
        final String filter;
        volatile long expires = SystemClock.elapsedRealtime() + CURSOR_TTL;
        long scanned;
        boolean closed;
        final AtomicBoolean cleaning = new AtomicBoolean();
        Page(Scope scope, Ref parent, Cursor cursor, String filter) {
            this.scope = scope; this.parent = parent; this.cursor = cursor; this.filter = filter; revision = scope.revision;
        }
    }
    private static final class Watch {
        final String key, id = UUID.randomUUID().toString();
        final Scope scope;
        volatile long revision;
        volatile boolean initialized, closed, observing;
        ContentObserver observer;
        final AtomicBoolean cleaning = new AtomicBoolean();
        final SafWorkspaceChangeHint metadata = new SafWorkspaceChangeHint();
        final SafWorkspaceEntryHints<Ref> entries = new SafWorkspaceEntryHints<>(64);
        boolean probing;
        long nextProbe;
        Cursor cursor; // An exhausted list cursor keeps FileSystemProvider FileObserver alive.
        Watch(String key, Scope scope) { this.key = key; this.scope = scope; }
    }
    private static final class Reply implements Closeable {
        final JSONObject payload;
        ParcelFileDescriptor descriptor;
        Page newPage;
        Reply(JSONObject payload) { this.payload = payload; }
        @Override public void close() { if (descriptor != null) { try { descriptor.close(); } catch (IOException ignored) {} descriptor = null; } }
    }
    private final class Call {
        final MethodChannel.Result result;
        final String key;
        final long owner;
        final CancellationSignal signal = new CancellationSignal();
        final AtomicBoolean replied = new AtomicBoolean();
        Call(MethodChannel.Result result, String key, long owner) { this.result = result; this.key = key; this.owner = owner; }
        void fail(String code) { main.post(() -> { if (replied.compareAndSet(false, true)) result.error(code, code, null); }); }
        void cancel() {
            fail("cancelled");
            try { cancellation.execute(signal::cancel); } catch (java.util.concurrent.RejectedExecutionException ignored) { /* Real worker still owns its budget. */ }
        }
    }
    public void request(long caller, String json, MethodChannel.Result result) {
        try {
            if (json == null || json.length() > 32768) throw new Failure("invalid");
            JSONObject request = new JSONObject(json);
            if (request.getInt("version") != 1) throw new Failure("invalid");
            String op = request.getString("op");
            String id = uuid(request.getString("requestId"));
            if ("cancel".equals(op)) { work.cancel(id, caller); result.success(payload(new JSONObject().put("version", 1))); return; }
            synchronized (this) { if (caller != owner) throw new Failure("cancelled"); }
            if (!java.util.Arrays.asList("probe", "list", "open", "close", "state").contains(op)) throw new Failure("invalid");
            String key = scopeKey(request);
            if ("close".equals(op)) {
                AndroidSafWorkspaceWrite.cancelScope(caller, key);
                synchronized (this) { Scope scope = scopes.get(key); if (scope != null && scope.owner == caller) scope.closed = true; }
                for (Map.Entry<String, Call> entry : calls.entrySet()) {
                    if (entry.getValue().owner == caller && entry.getValue().key.equals(key)) work.cancel(entry.getKey(), caller);
                }
                sweep(); result.success(payload(new JSONObject().put("version", 1))); return;
            }
            Call call = new Call(result, key, caller);
            if (calls.putIfAbsent(id, call) != null) { result.error("busy", "busy", null); return; }
            boolean admitted = work.submit(id, caller, call::cancel, ticket -> {
                Reply reply = null;
                try {
                    check(ticket, null);
                    reply = execute(request, ticket, call.signal);
                    check(ticket, null);
                    deliver(call, ticket, reply);
                    reply = null;
                } catch (Throwable error) {
                    if (reply != null) { reply.close(); if (reply.newPage != null) closePage(reply.newPage); }
                    call.fail(code(error));
                } finally { calls.remove(id, call); }
            });
            if (!admitted) { calls.remove(id, call); result.error("busy", "busy", null); }
        } catch (Exception error) { result.error(code(error), code(error), null); }
    }
    private void deliver(Call call, SafWorkspaceWork.Ticket ticket, Reply reply) throws InterruptedException {
        CountDownLatch delivered = new CountDownLatch(1);
        main.post(() -> {
            Integer fd = null;
            try {
                synchronized (ticket) {
                    if (ticket.cancelled() || ticket.owner != owner || !call.replied.compareAndSet(false, true)) {
                        if (reply.newPage != null) reply.newPage.expires = 0;
                        if (!call.replied.get()) call.fail("cancelled");
                        return;
                    }
                    Map<String, Object> response = payload(reply.payload);
                    if (reply.descriptor != null) { fd = reply.descriptor.detachFd(); response.put("fd", fd); }
                    call.result.success(response);
                    fd = null; // Dart/Rust now owns the detached descriptor.
                }
            } catch (Exception error) {
                if (fd != null) try { ParcelFileDescriptor.adoptFd(fd).close(); } catch (IOException ignored) {}
            } finally { reply.close(); delivered.countDown(); }
        });
        delivered.await();
    }
    private static Map<String, Object> payload(JSONObject value) {
        Map<String, Object> result = new HashMap<>(); result.put("payload", value.toString()); return result;
    }
    private static String scopeKey(JSONObject request) throws Exception {
        String workspace = uuid(request.getString("workspaceId"));
        Object generation = request.get("generation");
        if (!(generation instanceof Integer || generation instanceof Long) || ((Number) generation).longValue() < 0) throw new Failure("invalid");
        String tree = request.getString("tree");
        if (tree.length() > 8192) throw new Failure("invalid");
        String sourceOwner = uuid(request.getString("owner"));
        return sourceOwner + ":" + workspace + ":" + generation + ":" + tree;
    }
    private static String uuid(String value) throws Failure {
        try { if (!UUID.fromString(value).toString().equals(value)) throw new Exception(); return value; }
        catch (Exception error) { throw new Failure("invalid"); }
    }
    private static String code(Throwable error) {
        if (error instanceof Failure) return ((Failure) error).code;
        if (error instanceof SecurityException) return "permission";
        if (error instanceof android.os.OperationCanceledException) return "cancelled";
        if (error instanceof java.io.FileNotFoundException) return "not_found";
        if (error instanceof org.json.JSONException || error instanceof IllegalArgumentException) return "invalid";
        return "provider_error";
    }
    private void check(SafWorkspaceWork.Ticket ticket, Scope scope) throws Failure {
        if (ticket.cancelled() || ticket.owner != owner || (scope != null && scope.closed)) throw new Failure("cancelled");
    }
    static final class WriteParent {
        final String scopeKey, tree, parent;
        final int depth;
        final java.util.function.BooleanSupplier active;
        WriteParent(String key, String tree, String parent, int depth, java.util.function.BooleanSupplier active) {
            this.scopeKey = key; this.tree = tree; this.parent = parent; this.depth = depth; this.active = active;
        }
    }
    WriteParent resolveWriteParent(JSONObject request, long caller, CancellationSignal signal) throws Exception {
        if (caller != owner) throw new Failure("cancelled");
        String key = scopeKey(request);
        Uri tree = tree(request.getString("tree"));
        SafWorkspaceWork.Ticket ticket = new SafWorkspaceWork.Ticket("write-parent", caller, () -> {});
        Scope scope = scope(key, tree, ticket, signal);
        String token = request.getString("parent");
        Ref parent;
        synchronized (scope) { parent = scope.refs.get(token); }
        if (parent == null) throw new Failure("not_found");
        Ref current = stat(tree, parent.id, parent.depth, signal);
        check(ticket, scope);
        if (!current.directory || current.virtual) throw new Failure("unsupported");
        String uri = DocumentsContract.buildDocumentUriUsingTree(tree, current.id).toString();
        new AndroidSafReceiveTransaction(resolver).authorize(tree.toString(), uri);
        check(ticket, scope);
        return new WriteParent(key, tree.toString(), uri, current.depth, () -> caller == owner && !scope.closed);
    }

    private Uri tree(String value) throws Failure {
        if (value.length() > 8192) throw new Failure("invalid");
        Uri tree = Uri.parse(value);
        if (!"content".equals(tree.getScheme()) || tree.getAuthority() == null || tree.getQuery() != null || tree.getFragment() != null
            || !DocumentsContract.isTreeUri(tree) || tree.getPathSegments().size() != 2 || !"tree".equals(tree.getPathSegments().get(0))) throw new Failure("invalid");
        boolean granted = false;
        for (UriPermission grant : resolver.getPersistedUriPermissions()) {
            if (grant.isReadPermission() && tree.equals(grant.getUri())) { granted = true; break; }
        }
        if (!granted) throw new Failure("permission");
        return tree;
    }
    private static void complete(Cursor cursor) throws Failure {
        Bundle extras = cursor.getExtras();
        if (extras != null && extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw new Failure("provider_error");
        if (extras != null && extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) throw new Failure("loading");
    }
    private Ref read(Cursor cursor, int depth) throws Exception {
        String id = cursor.getString(0), name = cursor.getString(1), mime = cursor.getString(2);
        if (id == null || id.isEmpty() || id.length() > 8192 || name == null || name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 4096 || name.indexOf(0) >= 0 || mime == null || mime.length() > 512) throw new Failure("provider_error");
        Long size = cursor.isNull(3) ? null : cursor.getLong(3);
        if (size != null && size < 0) size = null;
        int modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
        Long modified = modifiedColumn < 0 || cursor.isNull(modifiedColumn) ? null : cursor.getLong(modifiedColumn);
        return new Ref(id, name, mime, size, modified, (cursor.getLong(4) & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0, depth);
    }
    private Ref stat(Uri tree, String id, int depth, CancellationSignal signal) throws Exception {
        Uri uri = DocumentsContract.buildDocumentUriUsingTree(tree, id);
        try (Cursor cursor = resolver.query(uri, COLUMNS, null, null, null, signal)) {
            if (cursor == null) throw new Failure("provider_error");
            complete(cursor);
            if (!cursor.moveToNext()) throw new Failure("not_found");
            Ref ref = read(cursor, depth);
            if (!id.equals(ref.id) || cursor.moveToNext()) throw new Failure("provider_error");
            complete(cursor); return ref;
        }
    }
    private Reply execute(JSONObject request, SafWorkspaceWork.Ticket ticket, CancellationSignal signal) throws Exception {
        String op = request.getString("op");
        Uri tree = tree(request.getString("tree"));
        String workspace = uuid(request.getString("workspaceId"));
        long generation = request.getLong("generation");
        if (generation < 0) throw new Failure("invalid");
        String key = scopeKey(request);
        if ("probe".equals(op)) {
            Ref root = stat(tree, DocumentsContract.getTreeDocumentId(tree), 0, signal);
            check(ticket, null);
            if (!root.directory) throw new Failure("unsupported");
            boolean writable = false;
            try {
                AndroidSafDirectory backend = new AndroidSafDirectory(resolver);
                String rootUri = backend.writableRoot(tree.toString());
                SafDirectoryResolver.Document destination = backend.stat(rootUri);
                writable = destination != null && destination.directory && destination.canCreate;
            } catch (java.io.IOException | SecurityException ignored) { /* Read grant remains useful. */ }
            check(ticket, null);
            return new Reply(new JSONObject().put("version", 1).put("readable", true).put("writable", writable));
        }
        Scope scope = scope(key, tree, ticket, signal);
        check(ticket, scope);
        String document = request.optString("documentId", "");
        Ref ref;
        synchronized (scope) { ref = scope.refs.get(document); }
        if (ref == null) throw new Failure("not_found");
        if ("state".equals(op)) {
            Ref current = stat(tree, ref.id, ref.depth, signal);
            check(ticket, scope);
            return state(ticket, scope, current, signal);
        }
        if ("open".equals(op)) {
            long revision = scope.revision;
            Ref current = stat(tree, ref.id, ref.depth, signal);
            check(ticket, scope);
            if (current.directory || current.virtual || current.size == null) throw new Failure("unsupported");
            ParcelFileDescriptor fd = resolver.openFileDescriptor(DocumentsContract.buildDocumentUriUsingTree(tree, current.id), "r", signal);
            if (fd == null) throw new Failure("provider_error");
            try {
                check(ticket, scope);
                StructStat attributes = Os.fstat(fd.getFileDescriptor());
                if (!OsConstants.S_ISREG(attributes.st_mode) || attributes.st_size < 0 || attributes.st_size != current.size) throw new Failure("unsupported");
                if (Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_SET) != 0) throw new Failure("unsupported");
                tree(tree.toString()); check(ticket, scope);
                if (revision != scope.revision) throw new Failure("expired");
                Reply reply = new Reply(new JSONObject().put("version", 1).put("id", document).put("name", current.name)
                    .put("size", attributes.st_size).put("seekable", true).put("mime", current.mime));
                reply.descriptor = fd; fd = null; return reply;
            } finally { if (fd != null) fd.close(); }
        }
        return list(request, ticket, signal, scope, ref);
    }
    private Scope scope(String key, Uri tree, SafWorkspaceWork.Ticket ticket, CancellationSignal signal) throws Exception {
        synchronized (this) {
            Scope existing = scopes.get(key);
            if (existing != null) { if (existing.closed || existing.owner != ticket.owner) throw new Failure("expired"); if (!existing.initialized) throw new Failure("busy"); return existing; }
            if (scopes.size() >= MAX_SCOPES) throw new Failure("busy");
        }
        Ref root = stat(tree, DocumentsContract.getTreeDocumentId(tree), 0, signal);
        check(ticket, null);
        if (!root.directory) throw new Failure("unsupported");
        Scope created = new Scope(key, tree, ticket.owner);
        created.refs.put("", root); created.tokens.put(root.id, "");
        synchronized (this) {
            Scope existing = scopes.get(key);
            if (existing != null) { if (existing.closed) throw new Failure("expired"); if (!existing.initialized) throw new Failure("busy"); return existing; }
            if (scopes.size() >= MAX_SCOPES) throw new Failure("busy");
            check(ticket, null);
            long bytes = refBytes(root);
            if (!references.replace(1, bytes)) throw new Failure("busy");
            created.refBytes = bytes; scopes.put(key, created);
        }
        // Scope observers attach only to active query cursors. Foreground state
        // requests separately lease exact directory observers, never the whole tree.
        created.initialized = true;
        if (created.closed) sweep();
        return created;
    }
    private Reply state(SafWorkspaceWork.Ticket ticket, Scope scope, Ref parent, CancellationSignal signal) throws Exception {
        if (!parent.directory) throw new Failure("invalid");
        String key = scope.key + "\n" + parent.id;
        Watch watch;
        synchronized (this) {
            watch = watches.get(key);
            if (watch != null) {
                if (watch.closed || !watch.initialized) throw new Failure("busy");
                if (!watchBudget.reserve(scope.key, key, SystemClock.elapsedRealtime())) { watch.closed = true; sweep(); throw new Failure("expired"); }
            } else {
                if (!watchBudget.reserve(scope.key, key, SystemClock.elapsedRealtime())) throw new Failure("busy");
                watch = new Watch(key, scope); watches.put(key, watch);
            }
        }
        if (!watch.initialized) {
            final Watch current = watch;
            current.observer = new ContentObserver(main) {
                @Override public void onChange(boolean selfChange) {
                    synchronized (AndroidSafWorkspace.this) {
                        if (current.closed || current.scope.closed) return;
                        current.revision++; current.scope.revision++;
                    }
                    sweep();
                }
            };
            try {
                check(ticket, scope);
                resolver.registerContentObserver(DocumentsContract.buildDocumentUriUsingTree(scope.tree, parent.id), false, current.observer);
                resolver.registerContentObserver(DocumentsContract.buildChildDocumentsUriUsingTree(scope.tree, parent.id), false, current.observer);
                current.observing = true;
            } catch (RuntimeException error) {
                // A provider may not support notifications. Keep explicit refresh
                // usable and accurately report that observation was unavailable.
                try { resolver.unregisterContentObserver(current.observer); } catch (RuntimeException ignored) { }
                current.observing = false;
            } catch (Failure error) {
                current.closed = true; throw error;
            } finally { current.initialized = true; if (current.closed || scope.closed) sweep(); }
        }
        try { check(ticket, scope); } catch (Failure error) { watch.closed = true; sweep(); throw error; }
        if (watch.closed || !watchBudget.active(key, SystemClock.elapsedRealtime())) { watch.closed = true; sweep(); throw new Failure("expired"); }
        synchronized (this) {
            // Some providers accept observers but never emit a change. Reuse the
            // mandatory directory stat as an invalidation hint, not a strong
            // content version; no directory enumeration or recursive scan.
            if (watch.metadata.observe(parent.modified)) { watch.revision++; scope.revision++; }
        }
        // Coarse parent timestamps can miss a rapid rename/delete. Probe only
        // already listed entries, at most 16 per call and 64 per leased watch.
        // Provider calls stay outside locks and retain the existing real worker
        // permit until completion, even after the caller cancels.
        boolean probeEntries;
        synchronized (this) {
            probeEntries = !watch.probing && SystemClock.elapsedRealtime() >= watch.nextProbe;
            if (probeEntries) { watch.probing = true; watch.nextProbe = SystemClock.elapsedRealtime() + 1000; }
        }
        if (probeEntries) {
            try {
                for (SafWorkspaceEntryHints.Probe<Ref> probe : watch.entries.next(16)) {
                    check(ticket, scope);
                    Ref current;
                    boolean unknown = false;
                    try { current = stat(scope.tree, probe.id, probe.value.depth, signal); }
                    catch (Exception error) {
                        String failure = code(error);
                        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
                            if (cause instanceof SecurityException) throw new Failure("permission");
                            if (cause instanceof android.os.OperationCanceledException) throw new Failure("cancelled");
                            if (cause.getCause() == cause) break;
                        }
                        if ("permission".equals(failure) || "cancelled".equals(failure)) throw error;
                        // Providers may throw IllegalArgumentException when a
                        // previously issued ID was renamed. Do not turn this
                        // one metadata hint into a failed directory request.
                        tree(scope.tree.toString()); // Scope grant loss is real.
                        current = null; unknown = true;
                    }
                    check(ticket, scope);
                    synchronized (this) {
                        if (watch.closed || watches.get(key) != watch || !watchBudget.active(key, SystemClock.elapsedRealtime())) throw new Failure("expired");
                        if (unknown ? watch.entries.invalidated(probe) : watch.entries.observed(probe, current)) { watch.revision++; scope.revision++; }
                    }
                }
            } finally {
                synchronized (this) { watch.probing = false; }
            }
        }
        return new Reply(new JSONObject().put("version", 1).put("watchId", watch.id)
            .put("revision", watch.revision).put("observing", watch.observing));
    }
    private Reply list(JSONObject request, SafWorkspaceWork.Ticket ticket, CancellationSignal signal, Scope scope, Ref parent) throws Exception {
        int limit = request.optInt("limit", 100);
        String filter = request.optString("filter", "").toLowerCase(Locale.ROOT);
        if (limit < 1 || limit > 100 || filter.length() > 256 || !parent.directory || parent.depth >= 64) throw new Failure("invalid");
        String cursorToken = request.isNull("cursor") ? "" : request.optString("cursor", "");
        Page page;
        SafWorkspaceCursor position = cursorToken.isEmpty() ? null : SafWorkspaceCursor.parse(cursorToken);
        if (cursorToken.isEmpty()) {
            synchronized (this) { if (pages.size() >= MAX_CURSORS) throw new Failure("busy"); }
            Cursor cursor = resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(scope.tree, parent.id), COLUMNS, null, null, null, signal);
            if (cursor == null) throw new Failure("provider_error");
            page = new Page(scope, parent, cursor, filter);
            try {
                complete(cursor); check(ticket, scope);
                synchronized (this) { if (pages.size() >= MAX_CURSORS) throw new Failure("busy"); pages.put(page.token, page); }
                final String watchKey = scope.key + "\n" + parent.id;
                cursor.registerContentObserver(new ContentObserver(main) {
                    @Override public void onChange(boolean selfChange) {
                        synchronized (AndroidSafWorkspace.this) {
                            if (scope.closed) return;
                            scope.revision++;
                            Watch watch = watches.get(watchKey);
                            if (watch != null && !watch.closed) watch.revision++;
                        }
                        sweep();
                    }
                });
            } catch (Exception error) { closePage(page); throw error; }
        } else {
            synchronized (this) { page = pages.get(position.id); }
            if (page == null || page.scope != scope || !page.parent.id.equals(parent.id) || !page.filter.equals(filter)) throw new Failure("expired");
        }
        try {
            synchronized (page) {
                if (page.closed || page.expires < SystemClock.elapsedRealtime() || page.revision != scope.revision) throw new Failure("expired");
                if (position != null && !position.matches(page.scanned)) throw new Failure("expired");
                check(ticket, scope); complete(page.cursor);
                JSONArray entries = new JSONArray(); long offset = page.scanned;
                int encodedBytes = 2;
                boolean ended = false;
                for (int i = 0; i < limit; i++) {
                    // Stop before moving the cursor. One maximally escaped 4096-byte name
                    // plus MIME and envelope still leaves the final reply below 256 KiB.
                    if (encodedBytes >= 200 * 1024) break;
                    check(ticket, scope);
                    if (!page.cursor.moveToNext()) { ended = true; break; }
                    page.scanned++;
                    Ref ref = read(page.cursor, parent.depth + 1);
                    if (ref.id.equals(parent.id)) throw new Failure("provider_error");
                    if (!ref.name.toLowerCase(Locale.ROOT).contains(filter)) continue;
                    String token;
                    synchronized (scope) {
                        check(ticket, scope);
                        token = scope.tokens.get(ref.id);
                        Ref old = token == null ? null : scope.refs.get(token);
                        if (old != null && old.directory && old.depth <= parent.depth) throw new Failure("provider_error");
                        long delta = refBytes(ref) - (old == null ? 0 : refBytes(old));
                        synchronized (this) {
                            if (!references.replace(old == null ? 1 : 0, delta)) throw new Failure("busy");
                            scope.refBytes += delta;
                        }
                        if (token == null) {
                            token = UUID.randomUUID().toString(); scope.tokens.put(ref.id, token);
                        }
                        scope.refs.put(token, ref);
                    }
                    synchronized (this) {
                        Watch watch = watches.get(scope.key + "\n" + parent.id);
                        if (watch != null && !watch.closed && watchBudget.active(watch.key, SystemClock.elapsedRealtime())) {
                            watch.entries.listed(ref.id, ref);
                        }
                    }
                    JSONObject entry = new JSONObject().put("id", token).put("name", ref.name).put("directory", ref.directory)
                        .put("size", ref.size == null ? JSONObject.NULL : ref.size).put("mime", ref.mime)
                        .put("downloadable", !ref.directory && !ref.virtual && ref.size != null);
                    encodedBytes += entry.toString().getBytes(StandardCharsets.UTF_8).length + 1;
                    entries.put(entry);
                }
                complete(page.cursor); check(ticket, scope); tree(scope.tree.toString());
                if (page.revision != scope.revision) throw new Failure("expired");
                page.expires = SystemClock.elapsedRealtime() + CURSOR_TTL;
                Reply result = new Reply(new JSONObject().put("version", 1).put("entries", entries)
                    .put("cursor", ended ? JSONObject.NULL : SafWorkspaceCursor.encode(page.token, page.scanned)).put("offset", offset).put("scanned", page.scanned - offset));
                if (ended) closePage(page); else result.newPage = page;
                return result;
            }
        } catch (Exception error) { if (!"expired".equals(code(error))) closePage(page); throw error; }
    }
    private static long refBytes(Ref ref) { return 160L + 2L * (ref.id.length() + ref.name.length() + ref.mime.length()); }
    private void closePage(Page page) {
        synchronized (page) {
            if (page.closed) return;
            page.closed = true;
            boolean retained = false;
            synchronized (this) {
                Watch watch = watches.get(page.scope.key + "\n" + page.parent.id);
                if (watch != null && !watch.closed && watch.initialized && watch.observing
                    && !page.scope.closed && watch.cursor == null
                    && watchBudget.active(watch.key, SystemClock.elapsedRealtime())) {
                    // Transfer only after the page stops using the cursor. No extra
                    // query or materialization: one cursor per foreground watch.
                    watch.cursor = page.cursor; retained = true;
                }
            }
            try { if (!retained) page.cursor.close(); }
            finally { synchronized (this) { pages.remove(page.token, page); } }
        }
    }
    private void sweep() {
        List<Page> stale = new ArrayList<>(); List<Scope> closed = new ArrayList<>(); List<Watch> expiredWatches = new ArrayList<>();
        synchronized (this) {
            for (Page page : pages.values()) if (page.scope.closed || page.expires < SystemClock.elapsedRealtime() || page.revision != page.scope.revision) stale.add(page);
            for (Scope scope : scopes.values()) if (scope.closed && scope.initialized) closed.add(scope);
            for (Watch watch : watches.values()) {
                if (watch.scope.closed || !watchBudget.active(watch.key, SystemClock.elapsedRealtime())) watch.closed = true;
                if (watch.closed && watch.initialized) expiredWatches.add(watch);
            }
        }
        for (Watch watch : expiredWatches) {
            if (!watch.cleaning.compareAndSet(false, true)) continue;
            if (!work.submit(UUID.randomUUID().toString(), watch.scope.owner, () -> {}, ticket -> {
                try {
                    try {
                        if (watch.observer != null) { resolver.unregisterContentObserver(watch.observer); watch.observer = null; }
                    } catch (RuntimeException ignored) {
                        // Still attempt cursor cleanup. Keep the observer's owned
                        // slot for a bounded later retry if unregister failed.
                    } finally {
                        try {
                            if (watch.cursor != null) { watch.cursor.close(); watch.cursor = null; }
                        } catch (RuntimeException ignored) {
                            // A failed close is not successful resource release.
                        }
                    }
                    if (watch.observer == null && watch.cursor == null) {
                        synchronized (AndroidSafWorkspace.this) { watches.remove(watch.key, watch); watchBudget.released(watch.key); }
                    }
                } finally { watch.cleaning.set(false); }
            })) watch.cleaning.set(false);
        }
        for (Page page : stale) {
            if (!page.cleaning.compareAndSet(false, true)) continue;
            if (!work.submit(UUID.randomUUID().toString(), page.scope.owner, () -> {}, ticket -> closePage(page))) page.cleaning.set(false);
        }
        for (Scope scope : closed) {
            // No provider calls while holding the registry monitor. Unregister is dispatched with the same bounded pool.
            if (!scope.cleaning.compareAndSet(false, true)) continue;
            if (!work.submit(UUID.randomUUID().toString(), scope.owner, () -> {}, ticket -> {
                try {
                    // Cursor-local observers close with each cursor; no tree-wide registration exists.
                    synchronized (scope) {
                        synchronized (AndroidSafWorkspace.this) {
                            scopes.remove(scope.key, scope); references.replace(-scope.refs.size(), -scope.refBytes);
                        }
                        scope.refs.clear(); scope.tokens.clear(); scope.refBytes = 0;
                    }
                } finally { scope.cleaning.set(false); }
            })) scope.cleaning.set(false);
        }
    }
}
