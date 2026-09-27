package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Binding state-machine/field validation, not Android provider I/O. */
public final class SafReceiveCacheIdentityTest {
    static int checks;
    static final String SHA = "a".repeat(64);
    static void eq(Object got, Object want) { checks++; if (!Objects.equals(got, want)) throw new AssertionError(got + " != " + want); }
    interface Work { void run() throws IOException; }
    static void fails(String code, Work work) throws IOException {
        try { work.run(); throw new AssertionError("expected " + code); }
        catch (SafReceiveTransaction.Failure error) { eq(error.code, code); }
    }
    static final class Fixture implements SafReceiveTransaction.Backend, SafReceiveTransaction.Journal {
        final SafReceiveTransactionTest.Fake fake = new SafReceiveTransactionTest.Fake();
        final SafReceiveTransaction manager = new SafReceiveTransaction(this, this);
        SafReceiveTransaction.CacheIdentity identity;
        SafReceiveTransaction.Record record;
        boolean empty = true, live = true, failSave;
        int validations;
        Fixture() throws IOException {
            record = SafReceiveTransactionTest.begin(manager);
            record = manager.openReceive(record.id, "session", "file", "attempt");
            identity = SafReceiveCacheIdentityTest.identity(record.id, "cert:" + SHA, SHA, SHA, "name", 1048576L, 1048576L, 1, SHA);
        }
        public void authorize(String tree, String parent) throws IOException { fake.authorize(tree,parent); }
        public String create(String parent,String name) throws IOException { return fake.create(parent,name); }
        public String identity(String uri) throws IOException { return fake.identity(uri); }
        public void probe(String uri,String identity) throws IOException { fake.probe(uri,identity); }
        public boolean deleteOwned(String tree,String parent,String uri,String identity) throws IOException { return fake.deleteOwned(tree,parent,uri,identity); }
        public void prepareReceive(SafReceiveTransaction.Record r) throws IOException { fake.prepareReceive(r); }
        public void save(SafReceiveTransaction.Record r) throws IOException {
            if (failSave) throw new IOException("disk full"); fake.save(r);
        }
        public SafReceiveTransaction.Record load(String id) { return fake.load(id); }
        public void remove(String id) { fake.remove(id); }
        public SafReceiveTransaction.CacheIdentity parseCacheIdentity(String json) { return identity; }
        public void validateIdentityBinding(SafReceiveTransaction.Record r, boolean requireEmpty) throws IOException {
            validations++;
            if (!live || (requireEmpty && !empty)) throw new SafReceiveTransaction.Failure("STALE_HANDOFF", "changed or written");
        }
        void bind() throws IOException { manager.bindCacheIdentity(record.id,record.lease,"core","payload"); }
    }
    static SafReceiveTransaction.CacheIdentity identity(String task,String source,String resource,String version,String name,long size,long chunk,long created,String sha) {
        return new SafReceiveTransaction.CacheIdentity("json:" + task + source + resource + version + name + size + chunk + created + sha,
            task,source,resource,version,name,size,chunk,created,sha);
    }
    public static void main(String[] args) throws IOException {
        Fixture f = new Fixture(); f.bind();
        SafReceiveTransaction.Record stored = f.load(f.record.id);
        eq(stored.recoveryIdentity, f.identity.json); eq(stored.coreAttempt,"core"); eq(stored.size,1048576L); eq(stored.sha256,SHA);
        eq(stored.tree,"tree:opaque"); eq(stored.parent,"parent:actual"); eq(stored.desiredName,"already-exists.txt");
        eq(stored.copy().recoveryIdentity, f.identity.json);
        f.empty = false; f.bind(); eq(f.validations,2);
        fails("STALE_HANDOFF", () -> f.manager.bindCacheIdentity(f.record.id,f.record.lease,"different","payload"));
        fails("STALE_HANDOFF", () -> f.manager.bindCacheIdentity(f.record.id,"wrong","core","payload"));
        f.identity = identity(f.record.id,"http:127.0.0.1",SHA,SHA,"name",1048576L,1048576L,1,SHA);
        fails("STALE_HANDOFF",f::bind); eq(f.load(f.record.id).recoveryIdentity,stored.recoveryIdentity);
        Fixture nonempty = new Fixture(); nonempty.empty=false; fails("STALE_HANDOFF",nonempty::bind); eq(nonempty.load(nonempty.record.id).recoveryIdentity,null);
        Fixture revoked = new Fixture(); revoked.fake.granted=false; fails("PERMISSION_DENIED",revoked::bind); eq(revoked.load(revoked.record.id).recoveryIdentity,null);
        Fixture missing = new Fixture(); missing.live=false; fails("STALE_HANDOFF",missing::bind);
        Fixture released = new Fixture(); SafReceiveTransaction.Record r = released.load(released.record.id); r.receiveReleased=true; released.save(r);
        fails("STALE_HANDOFF",released::bind);
        Fixture published = new Fixture(); r=published.load(published.record.id);r.state=SafReceiveTransaction.State.PUBLISHED;published.save(r);
        fails("STALE_HANDOFF",published::bind);
        Fixture disk = new Fixture(); disk.failSave=true;
        try { disk.bind(); throw new AssertionError(); } catch(IOException expected) { checks++; }
        eq(disk.load(disk.record.id).recoveryIdentity,null); eq(disk.load(disk.record.id).coreAttempt,null);
        disk.failSave=false;disk.bind();eq(disk.load(disk.record.id).coreAttempt,"core");
        String task=UUID.randomUUID().toString();
        for(String source:List.of("cert:"+SHA,"cert:"+SHA.toUpperCase(Locale.ROOT),"http:127.0.0.1","http:fe80::1%3","http:::1")) {
            identity(task,source,SHA,SHA,"name",1048576L,1048576L,1,SHA).validate(task); checks++;
        }
        for(String source:List.of("localsend-v2:session","legnasend-resume:session","http:example.com","http:999.0.0.1","http:127.01.0.1","http:fe80::1%0","http:fe80::1%abc","cert:short","http:::::")) {
            fails("INVALID_ARGUMENT",()->identity(task,source,SHA,SHA,"name",1048576L,1048576L,1,SHA).validate(task));
        }
        List<SafReceiveTransaction.CacheIdentity> invalid=List.of(
            identity("wrong","cert:"+SHA,SHA,SHA,"name",1048576L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,"b".repeat(64),SHA,"name",1048576L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,"b".repeat(64),"name",1048576L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"name",1048575L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"name",1099511627777L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"name",1048576L,65536L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"name",1048576L,1048576L,0,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"",1048576L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"bad\0name",1048576L,1048576L,1,SHA),
            identity(task,"cert:"+SHA,SHA,SHA,"name",1048576L,1048576L,1,SHA.toUpperCase(Locale.ROOT)));
        for(SafReceiveTransaction.CacheIdentity invalidIdentity:invalid) fails("INVALID_ARGUMENT",()->invalidIdentity.validate(task));
        System.out.println("SAF cache identity binding: " + checks + " assertions passed (provider-neutral)");
    }
}
