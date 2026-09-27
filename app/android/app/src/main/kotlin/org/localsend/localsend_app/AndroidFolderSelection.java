package org.localsend.localsend_app;

import android.content.Context;
import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.OperationCanceledException;
import android.provider.DocumentsContract;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;

/** Two real provider workers, including blocked calls; destruction only cancels requests. */
final class AndroidFolderSelection {
    private static final ThreadPoolExecutor WORK = new ThreadPoolExecutor(2,2,30,TimeUnit.SECONDS,new ArrayBlockingQueue<Runnable>(2));
    private static final String[] COLUMNS = {
        DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_FLAGS
    };
    private final ContentResolver resolver;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<CancellationSignal> signals = ConcurrentHashMap.newKeySet();
    private volatile boolean closed;
    AndroidFolderSelection(Context context) {resolver=context.getApplicationContext().getContentResolver();}
    void close() {closed=true;for(CancellationSignal signal:signals)signal.cancel();}
    void read(Uri tree, MethodChannel.Result reply) {
        CancellationSignal signal=new CancellationSignal();signals.add(signal);
        try {
            WORK.execute(()->{
                Map<String,Object> value=null;String error=null;
                try {
                    SafFolderTree.Result selection=SafFolderTree.read(new SafFolderTree.Provider() {
                        public void check() throws Exception {
                            if(closed||signal.isCanceled())throw new OperationCanceledException();
                            boolean allowed=false;
                            for(android.content.UriPermission p:resolver.getPersistedUriPermissions())
                                if(p.isReadPermission()&&p.getUri().equals(tree)){allowed=true;break;}
                            if(!allowed)throw new SecurityException();
                        }
                        public SafFolderTree.Node root() throws Exception {
                            Uri uri=DocumentsContract.buildDocumentUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree));
                            try(Cursor cursor=query(uri,signal)) {
                                if(!cursor.moveToFirst())throw new SafFolderTree.Failure("unavailable");
                                return node(tree,cursor);
                            }
                        }
                        public SafFolderTree.Rows children(SafFolderTree.Node parent) throws Exception {
                            Cursor cursor=query(DocumentsContract.buildChildDocumentsUriUsingTree(tree,parent.id),signal);
                            return new SafFolderTree.Rows() {
                                public SafFolderTree.Node next() throws Exception {if(cursor.moveToNext())return node(tree,cursor);
                                    if(cursor.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING,false))throw new SafFolderTree.Failure("loading");
                                    if(cursor.getExtras().containsKey(DocumentsContract.EXTRA_ERROR))throw new SafFolderTree.Failure("unavailable");
                                    return null;}
                                public void close(){cursor.close();}
                            };
                        }
                    });
                    value=new HashMap<>();value.put("version",1);value.put("directoryUri",tree.toString());
                    value.put("emptyDirectories",selection.emptyDirectories);
                    ArrayList<Map<String,Object>> files=new ArrayList<>();
                    for(SafFolderTree.File file:selection.files) {
                        Map<String,Object> item=new HashMap<>();item.put("name",file.node.name);item.put("relativePath",file.relativePath);
                        item.put("uri",file.node.uri);item.put("size",file.node.size);item.put("modifiedMillis",file.node.modified);files.add(item);
                    }
                    value.put("files",files);
                } catch(SecurityException e) {error="permission";}
                  catch(OperationCanceledException e) {error="cancelled";}
                  catch(SafFolderTree.Failure e) {error=e.code;}
                  catch(Exception e) {error="unavailable";}
                finally {signals.remove(signal);}
                final Map<String,Object> completed=value;final String failure=error;
                main.post(()->{if(closed||signal.isCanceled())reply.error("cancelled","cancelled",null);
                    else if(failure!=null)reply.error(failure,failure,null);else reply.success(completed);});
            });
        } catch(RejectedExecutionException e) {signals.remove(signal);reply.error("busy","busy",null);}
    }
    private Cursor query(Uri uri,CancellationSignal signal) throws Exception {
        Cursor cursor=resolver.query(uri,COLUMNS,null,null,null,signal);
        if(cursor==null)throw new SafFolderTree.Failure("unavailable");
        try {
            if(cursor.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING,false))throw new SafFolderTree.Failure("loading");
            if(cursor.getExtras().containsKey(DocumentsContract.EXTRA_ERROR))throw new SafFolderTree.Failure("unavailable");
            return cursor;
        } catch(Exception e) {cursor.close();throw e;}
    }
    private static SafFolderTree.Node node(Uri tree,Cursor cursor) throws Exception {
        String id=cursor.getString(0),name=cursor.getString(1),mime=cursor.getString(2);
        if(id==null||id.length()>8192||name==null||mime==null||mime.isEmpty())throw new SafFolderTree.Failure("unsupported");
        int flags=cursor.isNull(5)?0:cursor.getInt(5);
        return new SafFolderTree.Node(id,name,DocumentsContract.buildDocumentUriUsingTree(tree,id).toString(),
            DocumentsContract.Document.MIME_TYPE_DIR.equals(mime),(flags&DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT)!=0,
            cursor.isNull(3)?null:cursor.getLong(3),cursor.isNull(4)||cursor.getLong(4)<=0?null:cursor.getLong(4));
    }
}
