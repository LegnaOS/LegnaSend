package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Private-journal state transitions; no Android provider/device acceptance. */
public final class SafReceiveRecoveryClaimTest {
    static int checks;
    static final String SHA = "a".repeat(64);
    static void eq(Object a,Object b){checks++;if(!Objects.equals(a,b))throw new AssertionError(a+" != "+b);}
    interface Work{void run()throws IOException;}
    static void fails(Work work)throws IOException{try{work.run();throw new AssertionError();}catch(IOException expected){checks++;}}
    static final class Fixture implements SafReceiveTransaction.Backend,SafReceiveTransaction.Journal {
        final SafReceiveTransactionTest.Fake fake=new SafReceiveTransactionTest.Fake();
        final Map<String,SafReceiveTransaction.CacheIdentity> identities=new HashMap<>();
        final SafReceiveTransaction manager=new SafReceiveTransaction(this,this);
        String failTarget;boolean failed,failRollback;
        public void authorize(String t,String p)throws IOException{fake.authorize(t,p);}
        public String create(String p,String n)throws IOException{return fake.create(p,n);}
        public String identity(String uri)throws IOException{return fake.identity(uri);}
        public void probe(String uri,String proof)throws IOException{fake.probe(uri,proof);}
        public boolean deleteOwned(String t,String p,String u,String i)throws IOException{return fake.deleteOwned(t,p,u,i);}
        public void prepareReceive(SafReceiveTransaction.Record r)throws IOException{fake.prepareReceive(r);}
        public void validateIdentityBinding(SafReceiveTransaction.Record r,boolean empty){}
        public SafReceiveTransaction.CacheIdentity parseCacheIdentity(String json)throws IOException{
            SafReceiveTransaction.CacheIdentity identity=identities.get(json);if(identity==null)throw new IOException("unknown JSON");return identity;
        }
        public void save(SafReceiveTransaction.Record r)throws IOException{
            if(Objects.equals(failTarget,r.id)&&r.recoverySourceId!=null&&!failed){failed=true;throw new IOException("target journal failed");}
            if(failRollback&&failed&&r.recoveryClaimId==null&&!Objects.equals(failTarget,r.id))throw new IOException("rollback failed");
            fake.save(r);
        }
        public SafReceiveTransaction.Record load(String id){return fake.load(id);}
        public void remove(String id){fake.remove(id);}
        SafReceiveTransaction.Record create(long time,String peer,String parent,String name)throws IOException{
            SafReceiveTransaction.Record r=manager.begin("tree",parent,name,"session","file","attempt");
            r=manager.openReceive(r.id,"session","file","attempt");
            String json="json-"+r.id;
            identities.put(json,new SafReceiveTransaction.CacheIdentity(json,r.id,peer,SHA,SHA,"received-file",1048576,1048576,time,SHA));
            manager.bindCacheIdentity(r.id,r.lease,"core-"+r.id,json);return load(r.id);
        }
        SafReceiveTransaction.Record create(long time)throws IOException{return create(time,"cert:"+SHA,"parent","name");}
        boolean claim(SafReceiveTransaction.Record target,SafReceiveTransaction.Record source,long now)throws IOException{
            return manager.claimRecovery(target.id,target.lease,target.coreAttempt,source.id,now);
        }
    }
    public static void main(String[]args)throws IOException{
        Fixture f=new Fixture();SafReceiveTransaction.Record source=f.create(1000),target=f.create(2000),other=f.create(2001);
        eq(f.claim(target,source,3000),true);
        eq(f.load(source.id).recoveryClaimId,target.id);eq(f.load(target.id).recoverySourceId,source.id);
        eq(f.claim(other,source,3000),false);eq(f.claim(target,source,3000),false);
        fails(()->f.manager.completeRecovery(target.id,"wrong",target.coreAttempt,source.id,2097152L,"b".repeat(64)));
        fails(()->f.manager.completeRecovery(target.id,target.lease,"wrong",source.id,2097152L,"b".repeat(64)));
        fails(()->f.manager.completeRecovery(target.id,target.lease,target.coreAttempt,other.id,2097152L,"b".repeat(64)));
        f.manager.completeRecovery(target.id,target.lease,target.coreAttempt,source.id,2097152L,"b".repeat(64));
        eq(f.load(source.id).recoverySupersededBy,target.id);eq(f.load(target.id).recoveryCompleted,true);
        f.manager.completeRecovery(target.id,target.lease,target.coreAttempt,source.id,2097152L,"b".repeat(64));checks++;
        // Failed target after drained handles releases only its bidirectional claim.
        f.manager.releaseRecoveryClaim(f.load(target.id));eq(f.load(source.id).recoveryClaimId,null);
        eq(f.load(source.id).recoverySupersededBy,null);eq(f.load(target.id).recoverySourceId,null);
        eq(f.claim(other,source,3000),true);
        f.manager.releaseRecoveryClaim(target);eq(f.load(source.id).recoveryClaimId,other.id);

        for(String mismatch:List.of("name","parent","peer","future","expired","released","output","published","identity","size","claim","superseded")){
            Fixture x=new Fixture();SafReceiveTransaction.Record old=x.create(1000),fresh=x.create(2000);
            if(mismatch.equals("name"))fresh=x.create(2000,"cert:"+SHA,"parent","other");
            if(mismatch.equals("parent"))fresh=x.create(2000,"cert:"+SHA,"other","name");
            if(mismatch.equals("peer"))fresh=x.create(2000,"http:127.0.0.1","parent","name");
            SafReceiveTransaction.Record changed=x.load(old.id);
            if(mismatch.equals("released"))changed.receiveReleased=true;
            if(mismatch.equals("output"))changed.output=new SafReceiveTransaction.Document("user:output","proof");
            if(mismatch.equals("published"))changed.state=SafReceiveTransaction.State.PUBLISHED;
            if(mismatch.equals("identity"))changed.recoveryIdentity=null;
            if(mismatch.equals("size"))changed.size++;
            if(mismatch.equals("claim"))changed.recoveryClaimId="another";
            if(mismatch.equals("superseded"))changed.recoverySupersededBy="another";
            x.save(changed);
            eq(x.claim(fresh,old,mismatch.equals("future")?999:mismatch.equals("expired")?86401000:3000),false);
            eq(x.load(fresh.id).recoverySourceId,null);
        }
        Fixture published=new Fixture();SafReceiveTransaction.Record old=published.create(1000),fresh=published.create(2000);
        eq(published.claim(fresh,old,3000),true);published.manager.completeRecovery(fresh.id,fresh.lease,fresh.coreAttempt,old.id,2097152L,"b".repeat(64));
        SafReceiveTransaction.Record done=published.load(fresh.id);done.state=SafReceiveTransaction.State.PUBLISHED;published.save(done);
        published.manager.releaseRecoveryClaim(done);eq(published.load(old.id).recoverySupersededBy,fresh.id);
        for(boolean rollbackFails:new boolean[]{false,true}){
            Fixture broken=new Fixture();SafReceiveTransaction.Record a=broken.create(1000),b=broken.create(2000);
            broken.failTarget=b.id;broken.failRollback=rollbackFails;fails(()->broken.claim(b,a,3000));
            eq(broken.load(b.id).recoverySourceId,null);eq(broken.load(a.id).recoveryClaimId,rollbackFails?b.id:null);
        }
        Fixture rejection=new Fixture();SafReceiveTransaction.Record rejected=rejection.create(1000),failed=rejection.create(2000),retry=rejection.create(3000);
        eq(rejection.claim(failed,rejected,4000),true);
        rejection.manager.releaseRecoveryClaim(rejection.load(failed.id),true);
        eq(rejection.load(rejected.id).recoveryRejected,true);eq(rejection.claim(retry,rejected,4000),false);
        Fixture uncertain=new Fixture();SafReceiveTransaction.Record pending=uncertain.create(1000),approved=uncertain.create(2000);
        SafReceiveTransaction.Record receipt=uncertain.load(pending.id);receipt.state=SafReceiveTransaction.State.PUBLISHING;uncertain.save(receipt);
        eq(uncertain.manager.hasProtectedRecovery(approved.id,pending.id,3000),true);
        eq(uncertain.manager.hasProtectedRecovery(approved.id,pending.id,86401000),false);
        receipt.state=SafReceiveTransaction.State.PUBLICATION_FAILED;receipt.output=new SafReceiveTransaction.Document("output","proof");uncertain.save(receipt);
        eq(uncertain.manager.hasProtectedRecovery(approved.id,pending.id,3000),true);
        receipt.state=SafReceiveTransaction.State.PUBLISHED;uncertain.save(receipt);
        eq(uncertain.manager.hasProtectedRecovery(approved.id,pending.id,3000),false); // New user approval may intentionally redownload.
        Fixture proof=new Fixture();SafReceiveTransaction.Record proofSource=proof.create(1000),proofTarget=proof.create(2000);
        eq(proof.claim(proofTarget,proofSource,3000),true);
        for(long invalidLength:new long[]{-1,0,48,2199023255553L}) {
            fails(()->proof.manager.completeRecovery(proofTarget.id,proofTarget.lease,proofTarget.coreAttempt,proofSource.id,invalidLength,"b".repeat(64)));
        }
        for(String invalidHash:new String[]{"", "short", "B".repeat(64), null}) {
            fails(()->proof.manager.completeRecovery(proofTarget.id,proofTarget.lease,proofTarget.coreAttempt,proofSource.id,2097152L,invalidHash));
        }
        eq(proof.load(proofSource.id).recoveryLength,-1L);eq(proof.load(proofSource.id).recoverySupersededBy,null);
        proof.manager.completeRecovery(proofTarget.id,proofTarget.lease,proofTarget.coreAttempt,proofSource.id,2097152L,"b".repeat(64));
        eq(proof.load(proofSource.id).recoveryLength,2097152L);eq(proof.load(proofSource.id).recoverySha256,"b".repeat(64));
        eq(proof.load(proofSource.id).copy().recoverySha256,"b".repeat(64));
        fails(()->proof.manager.completeRecovery(proofTarget.id,proofTarget.lease,proofTarget.coreAttempt,proofSource.id,2097153L,"b".repeat(64)));
        fails(()->proof.manager.completeRecovery(proofTarget.id,proofTarget.lease,proofTarget.coreAttempt,proofSource.id,2097152L,"c".repeat(64)));
        fails(()->proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,proofSource.id)); // not published yet
        SafReceiveTransaction.Record publishedTarget=proof.load(proofTarget.id);
        publishedTarget.state=SafReceiveTransaction.State.PUBLISHED;publishedTarget.output=new SafReceiveTransaction.Document("final:user","owned");proof.save(publishedTarget);
        eq(proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,null).id,proofSource.id);
        eq(proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,proofSource.id).cache.uri,proofSource.cache.uri);
        fails(()->proof.manager.recoveryCleanupSource(proofTarget.id,"wrong",proofSource.id));
        fails(()->proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,UUID.randomUUID().toString()));
        SafReceiveTransaction.Record damaged=proof.load(proofSource.id);damaged.recoverySha256=null;proof.save(damaged);
        fails(()->proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,proofSource.id));
        damaged.recoverySha256="b".repeat(64);damaged.recoveryClaimId="another";proof.save(damaged);
        fails(()->proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,proofSource.id));
        damaged.recoveryClaimId=proofTarget.id;damaged.cache=null;proof.save(damaged);
        eq(proof.manager.recoveryCleanupSource(proofTarget.id,proofTarget.lease,proofSource.id).cache,null); // durable delete replay
        eq(proof.load(proofTarget.id).output.uri,"final:user");eq(proof.load(proofSource.id).staging.uri,proofSource.staging.uri);
        System.out.println("SAF recovery claims: "+checks+" assertions passed (private-journal simulation)");
    }
}
