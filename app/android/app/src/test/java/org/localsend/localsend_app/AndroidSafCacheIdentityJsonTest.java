package org.localsend.localsend_app;

import java.io.IOException;
import org.json.JSONObject;

/** Actual adapter JSON parser with a host JSON implementation; no provider I/O. */
public final class AndroidSafCacheIdentityJsonTest {
    static int checks;
    static final String ID = "19a3b3f0-141b-4c41-b421-2f68a0e929d3", SHA = "a".repeat(64);
    static void check(boolean ok) { checks++; if (!ok) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        AndroidSafReceiveTransaction adapter = new AndroidSafReceiveTransaction(null);
        JSONObject json = new JSONObject().put("taskId",ID).put("sourceId","cert:"+SHA).put("resourceId",SHA).put("version",SHA)
            .put("fileName","中文 %.txt").put("size",1048576L).put("chunkSize",1048576L).put("createdUnixMs",1L).put("sha256",SHA);
        String original = json.toString();
        SafReceiveTransaction.CacheIdentity parsed = adapter.parseCacheIdentity(original); parsed.validate(ID);
        check(parsed.sha256.equals(SHA)); check(parsed.size == 1048576L);
        JSONObject reordered = new JSONObject();
        for(String key:new String[] {"sha256","createdUnixMs","chunkSize","size","fileName","version","resourceId","sourceId","taskId"})
            reordered.put(key,json.get(key));
        check(adapter.parseCacheIdentity(reordered.toString()).json.equals(parsed.json));
        for(String invalid:new String[] {"not-json", "{}", json.put("token","secret").toString()}) {
            try { adapter.parseCacheIdentity(invalid); throw new AssertionError("invalid accepted"); }
            catch(IOException expected) { checks++; }
        }
        for(String key:new String[] {"size","chunkSize","createdUnixMs"}) {
            for(Object invalid:new Object[] {"1048576", 1048576.5, JSONObject.NULL, true}) {
                JSONObject changed = new JSONObject(original).put(key,invalid);
                try { adapter.parseCacheIdentity(changed.toString()); throw new AssertionError("wrong number accepted"); }
                catch(IOException expected) { checks++; }
            }
        }
        for(String key:new String[] {"taskId","sourceId","resourceId","version","fileName","sha256"}) {
            JSONObject changed = new JSONObject(original).put(key,42);
            try { adapter.parseCacheIdentity(changed.toString()); throw new AssertionError("wrong string accepted"); }
            catch(IOException expected) { checks++; }
        }
        System.out.println("Android cache identity JSON: " + checks + " assertions passed (host JSON parser, not provider/device)");
    }
}
