package org.localsend.localsend_app;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class SafWorkspaceWriteTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    private static final class Backend implements SafWorkspaceWriteDirectories.Backend {
        final Map<String,SafDirectoryResolver.Document> entries=new HashMap<>();
        final Map<String,String> parents=new HashMap<>();
        final List<String> deleted=new ArrayList<>();
        int nonce;
        boolean alias;
        public SafDirectoryResolver.Document find(String parent,String name) {
            return entries.values().stream().filter(d->parent.equals(parents.get(d.uri))&&name.equals(d.name)).findFirst().orElse(null);
        }
        public Set<String> children(String parent) {
            Set<String> found=new HashSet<>();
            for(String uri:entries.keySet())if(parent.equals(parents.get(uri)))found.add(uri);
            return found;
        }
        public String create(String parent,String name) {
            if(alias)return entries.keySet().iterator().next();
            String uri="document:"+(++nonce);
            entries.put(uri,new SafDirectoryResolver.Document(uri,name,true,true));parents.put(uri,parent);return uri;
        }
        public SafDirectoryResolver.Document stat(String uri){return entries.get(uri);}
        public boolean deleteEmpty(String parent,String uri,String name) {
            if(!children(uri).isEmpty()||!parent.equals(parents.get(uri))||!name.equals(entries.get(uri).name))return false;
            deleted.add(uri);entries.remove(uri);parents.remove(uri);return true;
        }
    }
    public static void main(String[] args)throws Exception {
        SafWorkspaceWriteGate cancelled=new SafWorkspaceWriteGate();
        check(cancelled.cancel());check(!cancelled.ready());check(!cancelled.commit());
        SafWorkspaceWriteGate committed=new SafWorkspaceWriteGate();check(committed.ready());check(committed.commit());
        CountDownLatch started=new CountDownLatch(1),release=new CountDownLatch(1),done=new CountDownLatch(1);
        Thread publication=new Thread(()->{started.countDown();try{release.await();committed.published();}catch(InterruptedException e){throw new RuntimeException(e);}finally{done.countDown();}});
        publication.start();check(started.await(1,TimeUnit.SECONDS));
        check(!committed.cancel()); // Does not wait for provider publication.
        SafWorkspaceWriteGate sibling=new SafWorkspaceWriteGate();check(sibling.ready());check(sibling.commit());sibling.published();
        release.countDown();check(done.await(1,TimeUnit.SECONDS));check(committed.phase()==SafWorkspaceWriteGate.Phase.PUBLISHED);check(!committed.cancel());
        SafWorkspaceWriteGate unknown=new SafWorkspaceWriteGate();check(unknown.ready());check(unknown.commit());unknown.uncertain();check(!unknown.cancel());

        SafWorkspaceWriteDirectories dirs=new SafWorkspaceWriteDirectories();Backend backend=new Backend();
        SafWorkspaceWriteDirectories.Lease a=new SafWorkspaceWriteDirectories.Lease(),b=new SafWorkspaceWriteDirectories.Lease();
        List<String> journal=new ArrayList<>();
        SafWorkspaceWriteDirectories.Journal record=(parent,name,uri,proven)->journal.add(name+":"+uri+":"+proven);
        String parent=dirs.resolve(backend,"root",Arrays.asList("nested","unicode-目录"),a,()->{},record);
        check(journal.size()==6);check(journal.get(0).equals("nested:null:false"));
        check(dirs.resolve(backend,"root",Arrays.asList("nested","unicode-目录"),b,()->{},record).equals(parent));
        dirs.finish(backend,a,false);check(backend.deleted.isEmpty());
        dirs.finish(backend,b,true);check(backend.deleted.isEmpty()); // Sibling publication owns the parent.
        SafWorkspaceWriteDirectories.Lease c=new SafWorkspaceWriteDirectories.Lease();
        dirs.resolve(backend,"root",Arrays.asList("temporary","empty"),c,()->{},record);
        dirs.finish(backend,c,false);check(backend.deleted.size()==2); // Reverse empty-only removal.
        dirs.finish(backend,c,false);check(backend.deleted.size()==2);
        SafWorkspaceWriteDirectories.Lease d=new SafWorkspaceWriteDirectories.Lease();
        try {dirs.resolve(backend,"root",Arrays.asList("nested"),d,()->{},record,true);throw new AssertionError();}catch(IOException expected){check("conflict".equals(expected.getMessage()));}
        dirs.finish(backend,d,false);check(backend.deleted.size()==2);
        AtomicBoolean live=new AtomicBoolean(true);SafWorkspaceWriteDirectories.Lease e=new SafWorkspaceWriteDirectories.Lease();
        try {dirs.resolve(backend,"root",Arrays.asList("cancelled","never-created"),e,()->{if(!live.get())throw new IOException("cancelled");},
            (p,n,u,proven)->{if(proven)live.set(false);});throw new AssertionError();}catch(IOException expected){check("cancelled".equals(expected.getMessage()));}
        check(backend.find("root","cancelled")!=null);check(backend.find(backend.find("root","cancelled").uri,"never-created")==null);
        dirs.finish(backend,e,false);check(backend.find("root","cancelled")==null);
        SafWorkspaceWriteDirectories.Lease f=new SafWorkspaceWriteDirectories.Lease();
        try {dirs.resolve(backend,"root",Arrays.asList("journal-fail"),f,()->{},(p,n,u,proven)->{throw new IOException("disk");});throw new AssertionError();}catch(IOException expected){}
        check(backend.find("root","journal-fail")==null);
        backend.alias=true;int count=backend.entries.size();
        try {dirs.resolve(backend,"root",Arrays.asList("alias"),new SafWorkspaceWriteDirectories.Lease(),()->{},record);throw new AssertionError();}catch(IOException expected){check("publication_unconfirmed".equals(expected.getMessage()));}
        check(backend.entries.size()==count);
        System.out.println("PASS: cancellation/commit outcome ownership, independent gates, shared nested-directory leases, empty-only rollback, conservative conflicts/alias, journal-before-mutation, cancelled path stepping");
    }
}
