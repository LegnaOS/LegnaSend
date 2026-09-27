package org.localsend.localsend_app;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.provider.DocumentsContract;
import android.util.AtomicFile;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONArray;
import org.json.JSONObject;

/** Private scoped writes. Every provider transaction has its own long-I/O lock. */
public final class AndroidSafWorkspaceWrite {
    private static AndroidSafWorkspaceWrite instance;
    public static synchronized AndroidSafWorkspaceWrite get(Context context) {
        if (instance == null) instance = new AndroidSafWorkspaceWrite(context.getApplicationContext());
        return instance;
    }
    static void cancelScope(long owner, String scope) {
        AndroidSafWorkspaceWrite value;
        synchronized (AndroidSafWorkspaceWrite.class) { value = instance; }
        if (value != null) value.invalidate(owner, scope);
    }
    private final Context context;
    private final ContentResolver resolver;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final SafWorkspaceWork work = new SafWorkspaceWork(8);
    private final SafWorkspaceWriteDirectories directories = new SafWorkspaceWriteDirectories();
    private final Map<String, Transaction> transactions = new HashMap<>();
    private final Map<String, String> destinations = new HashMap<>();
    private final Map<String, Call> calls = new ConcurrentHashMap<>();
    private final AndroidSafReceiveTransaction.Journal journal;
    private AndroidSafWorkspaceWrite(Context context) {
        this.context = context; resolver = context.getContentResolver();
        journal = new AndroidSafReceiveTransaction.Journal(context, "saf-workspace-write-transactions-v1");
    }
    private static final class Failure extends IOException {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    private final class Transaction {
        final long owner;
        final String key, scope, attempt, tree, path, parentToken, reservation;
        final boolean directory;
        final long size;
        final SafWorkspaceWriteGate gate = new SafWorkspaceWriteGate();
        final SafWorkspaceWriteDirectories.Lease directoryLease = new SafWorkspaceWriteDirectories.Lease();
        final AndroidSafReceiveTransaction backend = new AndroidSafReceiveTransaction(resolver, true,
            () -> gate.phase()!=SafWorkspaceWriteGate.Phase.CANCELLED &&
                (gate.phase()==SafWorkspaceWriteGate.Phase.COMMITTING || this.authority==null || this.authority.active.getAsBoolean()));
        final SafReceiveTransaction manager = new SafReceiveTransaction(backend, journal);
        final Object io = new Object(); // Only this transaction, never registry-wide.
        final AtomicBoolean releaseRequested = new AtomicBoolean();
        final JSONArray created = new JSONArray();
        final String journalId = UUID.randomUUID().toString();
        String id = UUID.randomUUID().toString(), lease = UUID.randomUUID().toString();
        String parent, desiredName;
        SafReceiveTransaction.Record record;
        AndroidSafWorkspace.WriteParent authority;
        volatile boolean handedOff, released;
        volatile long retiredAt;
        Transaction(long owner, JSONObject request, String scope) throws Exception {
            this.owner = owner; this.scope = scope; attempt = uuid(request.getString("attemptId"));
            key = scope + "\n" + attempt; tree = request.getString("tree");
            path = request.getString("path"); parentToken = request.getString("parent");
            Object length = request.get("size");
            if (!(length instanceof Integer || length instanceof Long)) throw new Failure("invalid");
            size = ((Number) length).longValue();
            Object kind = request.get("directory"); if (!(kind instanceof Boolean)) throw new Failure("invalid");
            directory = (Boolean) kind;
            if (size < 0 || size > 9007199254740991L || (directory && size != 0)) throw new Failure("invalid");
            components(path);
            if (!parentToken.isEmpty()) uuid(parentToken);
            reservation = scope + "\n" + parentToken + "\n" + path;
        }
        void active(SafWorkspaceWork.Ticket ticket) throws IOException {
            if (ticket.cancelled() || gate.phase() == SafWorkspaceWriteGate.Phase.CANCELLED
                || (authority != null && !authority.active.getAsBoolean())) throw new Failure("cancelled");
        }
        void saveDirectories(String parent, String name, String uri, boolean proven) throws IOException {
            try {
                if (uri == null && created.toString().getBytes(StandardCharsets.UTF_8).length > 192 * 1024) throw new Failure("busy");
                if (uri != null && uri.getBytes(StandardCharsets.UTF_8).length > 16384) throw new Failure("publication_unconfirmed");
                created.put(new JSONObject().put("parent", parent).put("name", name)
                    .put("uri", uri == null ? JSONObject.NULL : uri).put("proven", proven));
                saveMetadata();
            } catch (org.json.JSONException e) { throw new IOException(e); }
        }
        void saveMetadata() throws IOException {
            File dir = new File(context.getFilesDir(), "saf-workspace-write-directories-v1");
            if (!dir.mkdirs() && !dir.isDirectory()) throw new IOException("journal unavailable");
            AtomicFile file = new AtomicFile(new File(dir, journalId + ".json"));
            FileOutputStream stream = null;
            try {
                JSONObject value = new JSONObject().put("version",1).put("scope",scope).put("attemptId",attempt)
                    .put("tree",tree).put("path",path).put("parent",parentToken).put("transactionId",id)
                    .put("phase",gate.phase().name()).put("created",created);
                byte[] bytes=value.toString().getBytes(StandardCharsets.UTF_8);
                if(bytes.length>256*1024)throw new Failure("busy");
                stream = file.startWrite(); stream.write(bytes);
                file.finishWrite(stream); stream = null;
            } catch (org.json.JSONException e) { throw new IOException(e); }
            finally { if (stream != null) file.failWrite(stream); }
        }
    }
    private final class Call {
        final long owner;
        final String id;
        final MethodChannel.Result result;
        final CancellationSignal signal = new CancellationSignal();
        final AtomicBoolean replied = new AtomicBoolean();
        volatile Transaction transaction;
        Call(long owner, String id, MethodChannel.Result result) { this.owner=owner;this.id=id;this.result=result; }
        void fail(String code) { main.post(() -> { if (replied.compareAndSet(false,true)) result.error(code,code,null); }); }
        void cancel() {
            Transaction tx = transaction;
            if (tx != null && !tx.gate.cancel()) return; // Real publication owns its outcome.
            fail("cancelled");
            // Do not run CancellationSignal.cancel on UI: a provider's listener
            // may block. The real worker checks the logical gate after its call.
        }
    }
    private static final class Reply implements AutoCloseable {
        final JSONObject payload;
        AndroidSafReceiveTransaction.OpenedPair pair;
        Reply(JSONObject payload) { this.payload = payload; }
        public void close() { if (pair != null) { try { pair.close(); } catch (IOException ignored) {} pair = null; } }
    }
    public void request(long owner, String raw, MethodChannel.Result result) {
        try {
            if (raw == null || raw.getBytes(StandardCharsets.UTF_8).length > 32768) throw new Failure("invalid");
            JSONObject request = new JSONObject(raw);
            if (request.getInt("version") != 1) throw new Failure("invalid");
            String requestId = uuid(request.getString("requestId")), op=request.getString("op");
            if ("cancelRequest".equals(op)) {
                work.cancel(requestId,owner); result.success(payload(new JSONObject().put("version",1))); return;
            }
            String scope = scope(request);
            String attempt = uuid(request.getString("attemptId"));
            if (!Arrays.asList("begin","publish","cancel","release").contains(op)) throw new Failure("invalid");
            Transaction tx;
            synchronized (this) {
                sweep(); tx = transactions.get(scope + "\n" + attempt);
                if ("begin".equals(op)) {
                    if (tx != null || transactions.values().stream().filter(entry -> !entry.released).count() >= 64) throw new Failure("busy");
                    tx = new Transaction(owner,request,scope);
                    if (destinations.containsKey(tx.reservation)) throw new Failure("conflict");
                    transactions.put(tx.key,tx); destinations.put(tx.reservation,tx.key);
                } else {
                    boolean malformedRelease = "release".equals(op) && request.isNull("transactionId") && request.isNull("lease");
                    if (tx == null || tx.owner != owner || (!malformedRelease &&
                        (!tx.id.equals(uuid(request.getString("transactionId"))) || !tx.lease.equals(request.getString("lease"))))) throw new Failure("expired");
                }
            }
            if ("cancel".equals(op)) {
                boolean cancelled = tx.gate.cancel();
                result.success(payload(new JSONObject().put("version",1).put("cancelled",cancelled)));
                return; // Never delete while the Rust descriptor lease is live.
            }
            if ("release".equals(op)) tx.releaseRequested.set(true);
            Call call = new Call(owner,requestId,result); call.transaction=tx;
            if (calls.putIfAbsent(requestId,call) != null) {
                if ("begin".equals(op)) synchronized(this) { transactions.remove(tx.key,tx);destinations.remove(tx.reservation,tx.key); }
                throw new Failure("busy");
            }
            Transaction current=tx;
            if (!work.submit(requestId,owner,call::cancel,ticket -> {
                Reply reply=null;
                try {
                    synchronized(current.io) {
                        if ("begin".equals(op)) reply=begin(request,current,ticket,call.signal);
                        else if ("publish".equals(op)) reply=publish(request,current,ticket);
                        else { cleanup(current); reply=new Reply(new JSONObject().put("version",1).put("released",current.released)); }
                        deliver(call,ticket,reply,"publish".equals(op)); reply=null;
                    }
                } catch(Throwable error) {
                    if (reply != null) reply.close();
                    call.fail(code(error));
                } finally {
                    if ("begin".equals(op) && !current.handedOff) {
                        current.gate.cancel(); current.releaseRequested.set(true);
                    }
                    if (current.releaseRequested.get()) synchronized(current.io) { cleanup(current); }
                    calls.remove(requestId,call);
                }
            })) {
                calls.remove(requestId,call);
                if ("begin".equals(op)) synchronized(this) { transactions.remove(current.key,current); destinations.remove(current.reservation,current.key); }
                result.error("busy","busy",null);
            }
        } catch(Exception error) { result.error(code(error),code(error),null); }
    }
    private Reply begin(JSONObject request, Transaction tx, SafWorkspaceWork.Ticket ticket, CancellationSignal signal) throws Exception {
        tx.active(ticket);
        tx.authority=AndroidSafWorkspace.get(context).resolveWriteParent(request,tx.owner,signal);
        tx.active(ticket); tx.saveMetadata();
        List<String> components=components(tx.path);
        tx.desiredName=components.get(components.size()-1);
        if (tx.authority.depth + components.size() > 64) throw new Failure("invalid");
        List<String> parents=components.subList(0,components.size()-1);
        tx.parent=directories.resolve(directoryBackend(tx),tx.authority.parent,parents,tx.directoryLease,
            ()->tx.active(ticket),tx::saveDirectories);
        tx.active(ticket);
        if (tx.directory) {
            tx.parent=directories.resolve(directoryBackend(tx),tx.parent,Arrays.asList(tx.desiredName),tx.directoryLease,
                ()->tx.active(ticket),tx::saveDirectories,true);
        }
        if (!tx.directory) {
            // A destination conflict is rejected, never silently renamed.
            if (new AndroidSafDirectory(resolver).findChild(tx.parent,tx.desiredName)!=null) throw new Failure("conflict");
            tx.record=tx.manager.begin(tx.tree,tx.parent,tx.desiredName,tx.scope,tx.attempt,tx.attempt);
            tx.id=tx.record.id;
            tx.active(ticket);
            tx.record=tx.manager.openReceive(tx.id,tx.scope,tx.attempt,tx.attempt);
            tx.lease=tx.record.lease;
            tx.active(ticket); tx.saveMetadata();
        }
        if (!tx.gate.ready()) throw new Failure("cancelled");
        Reply reply=new Reply(new JSONObject().put("version",1).put("transactionId",tx.id).put("lease",tx.lease));
        if (!tx.directory) reply.pair=tx.backend.duplicatePair(tx.record);
        return reply;
    }
    private Reply publish(JSONObject request,Transaction tx,SafWorkspaceWork.Ticket ticket) throws Exception {
        if (!tx.attempt.equals(uuid(request.getString("coreAttemptId")))) throw new Failure("invalid");
        Object size=request.get("size");
        if (!(size instanceof Integer || size instanceof Long) || ((Number)size).longValue()!=tx.size) throw new Failure("invalid");
        String sha=request.getString("sha256");
        if (tx.directory ? !sha.isEmpty() : !sha.matches("[0-9a-fA-F]{64}")) throw new Failure("invalid");
        if (tx.gate.phase()==SafWorkspaceWriteGate.Phase.PUBLISHED) return new Reply(new JSONObject().put("version",1).put("published",true));
        if (tx.gate.phase()==SafWorkspaceWriteGate.Phase.UNCONFIRMED) throw new Failure("publication_unconfirmed");
        tx.active(ticket);
        tx.backend.authorize(tx.tree,tx.parent);
        if (!tx.directory && new AndroidSafDirectory(resolver).findChild(tx.parent,tx.desiredName)!=null) throw new Failure("conflict");
        tx.active(ticket);
        if (!tx.handedOff || !tx.gate.commit()) throw new Failure("cancelled");
        try {
            tx.saveMetadata();
            if (tx.directory) {
                tx.backend.authorize(tx.tree,tx.parent);
                SafDirectoryResolver.Document current=new AndroidSafDirectory(resolver).stat(tx.parent);
                if (current==null || !current.directory || !tx.desiredName.equals(current.name)) throw new Failure("conflict");
            } else {
                tx.manager.publish(tx.id,tx.lease,tx.attempt,tx.size,sha);
            }
            tx.gate.published();
            tx.saveMetadata();
            return new Reply(new JSONObject().put("version",1).put("published",true));
        } catch(Exception error) {
            // Once provider publication was entered, a lost reply or persistence
            // error is not a proven failed copy. Preserve journal and output.
            boolean uncertain = tx.directory;
            if (!tx.directory) {
                try {
                    SafReceiveTransaction.Record actual=journal.load(tx.id);
                    uncertain=actual==null || actual.output!=null || actual.state==SafReceiveTransaction.State.PUBLISHING || actual.state==SafReceiveTransaction.State.PUBLISHED;
                } catch(IOException | RuntimeException unavailable) { uncertain=true; }
            }
            if (uncertain) { tx.gate.uncertain(); throw new Failure("publication_unconfirmed"); }
            tx.gate.failed(); throw error;
        }
    }
    private void cleanup(Transaction tx) {
        if (tx.released || tx.gate.phase()==SafWorkspaceWriteGate.Phase.COMMITTING) return;
        boolean committed=tx.gate.phase()==SafWorkspaceWriteGate.Phase.PUBLISHED;
        boolean unknown=tx.gate.phase()==SafWorkspaceWriteGate.Phase.UNCONFIRMED;
        try {
            if (tx.record!=null) {
                if (tx.record.lease!=null) {
                    SafReceiveTransaction.AbortResult result=tx.manager.abortReceiving(tx.id,tx.lease);
                    if (!result.complete && !committed && !unknown) return;
                } else tx.manager.abort(tx.id);
            }
            directories.finish(directoryBackend(tx),tx.directoryLease,committed||unknown);
            tx.released=true; tx.retiredAt=SystemClock.elapsedRealtime();
            // Keep confirmed or ambiguous outcome; never turn it into cancelled.
            if (!committed && !unknown) tx.gate.released();
            tx.saveMetadata();
            synchronized(this) { destinations.remove(tx.reservation,tx.key); }
        } catch(IOException | RuntimeException ignored) { /* Retain ownership/journal for a later explicit release. */ }
    }
    private void deliver(Call call,SafWorkspaceWork.Ticket ticket,Reply reply,boolean publication) throws InterruptedException {
        CountDownLatch done=new CountDownLatch(1);
        main.post(()->{
            Integer cache=null,staging=null;
            try {
                Transaction tx=call.transaction;
                synchronized(ticket) {
                    if ((!publication && (ticket.cancelled() || tx.gate.phase()==SafWorkspaceWriteGate.Phase.CANCELLED))
                        || !call.replied.compareAndSet(false,true)) return;
                    Map<String,Object> value=payload(reply.payload);
                    if(reply.pair!=null) {
                        cache=reply.pair.cache.detachFd(); staging=reply.pair.staging.detachFd();
                        value.put("cacheFd",cache);value.put("stagingFd",staging);
                    }
                    call.result.success(value);
                    cache=null;staging=null;tx.handedOff=true;
                }
            } catch(Exception ignored) {
                closeFd(cache); closeFd(staging);
            } finally { reply.close();done.countDown(); }
        });
        done.await();
    }
    private void invalidate(long owner,String scope) {
        List<Transaction> copy;
        synchronized(this) { copy=new ArrayList<>(transactions.values()); }
        for(Transaction tx:copy) if(tx.owner==owner && (scope==null || tx.scope.equals(scope))) tx.gate.cancel();
        for(Call call:calls.values()) if(call.owner==owner && (scope==null || call.transaction.scope.equals(scope))) work.cancel(call.id,owner);
    }
    private synchronized void sweep() {
        long now=SystemClock.elapsedRealtime();
        transactions.values().removeIf(tx->tx.released && now-tx.retiredAt>120000);
        // Completed receipts never impose a 64-files-per-two-minutes limit.
        while(transactions.size()>192) {
            Transaction oldest=transactions.values().stream().filter(tx->tx.released)
                .min(java.util.Comparator.comparingLong(tx->tx.retiredAt)).orElse(null);
            if(oldest==null)break;
            transactions.remove(oldest.key,oldest);
        }
    }
    private SafWorkspaceWriteDirectories.Backend directoryBackend(Transaction tx) {
        AndroidSafDirectory backend=new AndroidSafDirectory(resolver);
        return new SafWorkspaceWriteDirectories.Backend() {
            public SafDirectoryResolver.Document find(String parent,String name)throws IOException { tx.backend.authorize(tx.tree,parent);return backend.findChild(parent,name); }
            public Set<String> children(String parent)throws IOException { return childUris(tx.tree,parent); }
            public String create(String parent,String name)throws IOException { tx.backend.authorize(tx.tree,parent);return backend.createDirectory(parent,name); }
            public SafDirectoryResolver.Document stat(String uri)throws IOException { return backend.stat(uri); }
            public boolean deleteEmpty(String parent,String uri,String name)throws IOException {
                tx.backend.authorize(tx.tree,parent);
                SafDirectoryResolver.Document found=backend.findChild(parent,name);
                if(found==null || !uri.equals(found.uri) || !found.directory || !childUris(tx.tree,uri).isEmpty()) return false;
                return DocumentsContract.deleteDocument(resolver,Uri.parse(uri));
            }
        };
    }
    private Set<String> childUris(String tree,String parent)throws IOException {
        Uri root=Uri.parse(tree),uri=Uri.parse(parent);
        Set<String> result=new HashSet<>();
        long retainedBytes=0;
        try(Cursor cursor=resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(uri,DocumentsContract.getDocumentId(uri)),
            new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID},null,null,null)) {
            if(cursor==null) throw new IOException("provider_error");
            android.os.Bundle extras=cursor.getExtras();
            SafDirectoryResolver.requireCompleteListing(extras!=null&&extras.getBoolean(DocumentsContract.EXTRA_LOADING,false),extras!=null&&extras.containsKey(DocumentsContract.EXTRA_ERROR));
            while(cursor.moveToNext()) {
                if(result.size()>=100000)throw new IOException("busy");
                String id=cursor.getString(0);
                if(id==null||id.isEmpty()||id.length()>8192)throw new IOException("provider_error");
                String child=DocumentsContract.buildDocumentUriUsingTree(root,id).toString();
                retainedBytes+=64L+child.length()*2L;
                if(retainedBytes>16*1024*1024)throw new IOException("busy");
                if(!result.add(child))throw new IOException("provider_error");
            }
            extras=cursor.getExtras();
            SafDirectoryResolver.requireCompleteListing(extras!=null&&extras.getBoolean(DocumentsContract.EXTRA_LOADING,false),extras!=null&&extras.containsKey(DocumentsContract.EXTRA_ERROR));
        }
        return result;
    }
    private static List<String> components(String value)throws IOException {
        if(value==null || value.getBytes(StandardCharsets.UTF_8).length>4096 || value.isEmpty())throw new Failure("invalid");
        List<String> result=Arrays.asList(value.split("/",-1));
        if(result.size()>64)throw new Failure("invalid");
        for(String part:result)SafDirectoryResolver.validateName(part);
        return result;
    }
    private static String scope(JSONObject value)throws Exception {
        Object generation=value.get("generation");
        if(!(generation instanceof Integer||generation instanceof Long)||((Number)generation).longValue()<0)throw new Failure("invalid");
        String tree=value.getString("tree"); if(tree.length()>8192)throw new Failure("invalid");
        return uuid(value.getString("owner"))+":"+uuid(value.getString("workspaceId"))+":"+generation+":"+tree;
    }
    private static String uuid(String value)throws Failure {
        try { if(!UUID.fromString(value).toString().equals(value))throw new IllegalArgumentException();return value; }
        catch(Exception error){throw new Failure("invalid");}
    }
    private static Map<String,Object> payload(JSONObject value){Map<String,Object> result=new HashMap<>();result.put("payload",value.toString());return result;}
    private static void closeFd(Integer fd){if(fd!=null)try{ParcelFileDescriptor.adoptFd(fd).close();}catch(IOException ignored){}}
    private static String code(Throwable error){
        if(error instanceof Failure)return ((Failure)error).code;
        if(error instanceof SafReceiveTransaction.PublicationUncertain)return "publication_unconfirmed";
        if(error instanceof SecurityException)return "permission";
        if(error instanceof SafDirectoryResolver.Failure){String code=((SafDirectoryResolver.Failure)error).code;return code.equals("PERMISSION_DENIED")?"permission":code.equals("NAME_CONFLICT")?"conflict":"unsupported";}
        if(error instanceof SafReceiveTransaction.Failure){String code=((SafReceiveTransaction.Failure)error).code;return code.equals("CANCELLED")?"cancelled":code.equals("PERMISSION_DENIED")?"permission":code.equals("NAME_CONFLICT")?"conflict":code.equals("CAPABILITY_UNSUPPORTED")?"unsupported":"provider_error";}
        if(error instanceof org.json.JSONException||error instanceof IllegalArgumentException)return "invalid";
        if(error instanceof android.os.OperationCanceledException)return "cancelled";
        if(error instanceof IOException && Arrays.asList("conflict","publication_unconfirmed","busy").contains(error.getMessage()))return error.getMessage();
        return "provider_error";
    }
}
