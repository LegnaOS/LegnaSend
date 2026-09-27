package org.localsend.localsend_app;

import java.io.IOException;
import org.json.JSONObject;

/** Real adapter proof parser only; no Android provider or FD stub execution. */
public final class AndroidSafPublicationProofTest {
    static int checks;
    static final String ID = "19a3b3f0-141b-4c41-b421-2f68a0e929d3";
    static void check(boolean ok) { checks++; if (!ok) throw new AssertionError(); }
    static boolean accepts(Object proof) {
        SafReceiveTransaction.Record r = new SafReceiveTransaction.Record(ID, "tree", "parent", "name", "session", "file", "attempt");
        r.output = new SafReceiveTransaction.Document("content://provider/opaque-output", proof == null ? null : proof.toString());
        try { return AndroidSafReceiveTransaction.hasPublicationReconcileProof(r); }
        catch (IOException rejected) { return false; }
    }
    public static void main(String[] args) throws Exception {
        JSONObject proof = new JSONObject().put("version", 2).put("transactionId", ID).put("uri", "content://provider/opaque-output")
            .put("parent", "parent").put("name", "provider-renamed-中文.txt").put("device", 1L).put("inode", 42L);
        String json = proof.toString(); check(accepts(json));
        check(accepts(new JSONObject(json).put("device", 0).put("inode", Long.MAX_VALUE)));
        for (String key : new String[] {"version", "transactionId", "uri", "parent", "name", "device", "inode"}) {
            JSONObject missing = new JSONObject(json); missing.remove(key); check(!accepts(missing));
            check(!accepts(new JSONObject(json).put(key, JSONObject.NULL)));
            check(!accepts(new JSONObject(json).put(key, true)));
        }
        for (String key : new String[] {"version", "device", "inode"}) {
            for (Object value : new Object[] {"2", 2.5, -1}) check(!accepts(new JSONObject(json).put(key, value)));
        }
        for (String key : new String[] {"transactionId", "uri", "parent"}) {
            check(!accepts(new JSONObject(json).put(key, "replacement")));
            check(!accepts(new JSONObject(json).put(key, 42)));
        }
        check(!accepts(new JSONObject(json).put("version", 1)));
        check(!accepts(new JSONObject(json).put("inode", 0)));
        check(!accepts(new JSONObject(json).put("name", "")));
        check(!accepts(new JSONObject(json).put("name", "bad\0name")));
        check(!accepts(null)); check(!accepts("not-json")); check(!accepts("{}"));
        System.out.println("Android publication proof: " + checks + " assertions passed (host JSON, not provider/device)");
    }
}
