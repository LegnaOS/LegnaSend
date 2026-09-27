package org.localsend.localsend_app;

import java.io.IOException;
import org.json.JSONObject;

/** Actual adapter proof parser, with host JSON; provider identity needs separate device verification. */
public final class AndroidSafStagingProofTest {
    static int checks;
    static final String ID = "19a3b3f0-141b-4c41-b421-2f68a0e929d3";
    static void check(boolean value) { checks++; if (!value) throw new AssertionError(); }
    static SafReceiveTransaction.Document document(String uri, String name, long inode) throws Exception {
        return new SafReceiveTransaction.Document(uri, new JSONObject().put("version", 2).put("transactionId", ID)
            .put("uri", uri).put("parent", "parent").put("name", name).put("device", 1).put("inode", inode).toString());
    }
    static SafReceiveTransaction.Record record() throws Exception {
        SafReceiveTransaction.Record r = new SafReceiveTransaction.Record(ID, "tree", "parent", "name", "session", "file", "attempt");
        r.staging = document("stage", ".legnasend-receive-" + ID + ".part", 1);
        r.output = document("output", "name", 2); r.cache = document("cache", ".legnasend-receive-" + ID + ".ls", 3); return r;
    }
    static boolean accepts(SafReceiveTransaction.Record r) {
        try { return AndroidSafReceiveTransaction.hasPublishedStagingProof(r); } catch (IOException failure) { return false; }
    }
    public static void main(String[] args) throws Exception {
        SafReceiveTransaction.Record r = record(); check(accepts(r)); r.cache = null; check(accepts(r));
        for (String slot : new String[] {"stage", "output", "cache"}) {
            for (String field : new String[] {"version", "transactionId", "uri", "parent", "name", "device", "inode"}) {
                r = record(); SafReceiveTransaction.Document d = slot.equals("stage") ? r.staging : slot.equals("output") ? r.output : r.cache;
                JSONObject json = new JSONObject(d.identity); json.remove(field);
                SafReceiveTransaction.Document bad = new SafReceiveTransaction.Document(d.uri, json.toString());
                if (slot.equals("stage")) r.staging = bad; else if (slot.equals("output")) r.output = bad; else r.cache = bad;
                check(!accepts(r));
            }
        }
        r = record(); r.output = document("output", "name", 1); check(!accepts(r));
        r = record(); r.cache = document("cache", "cache", 1); check(!accepts(r));
        r = record(); r.staging = document("stage", "someone-elses.part", 1); check(!accepts(r));
        r = record(); r.staging = new SafReceiveTransaction.Document("stage", null); check(!accepts(r));
        r = record(); r.cache = new SafReceiveTransaction.Document("cache", "{}"); check(!accepts(r));
        r = record(); r.staging = new SafReceiveTransaction.Document("retarget", r.staging.identity); check(!accepts(r));
        r = record(); r.output = new SafReceiveTransaction.Document("retarget", r.output.identity); check(!accepts(r));
        r = record(); r.cache = new SafReceiveTransaction.Document("retarget", r.cache.identity); check(!accepts(r));
        System.out.println("Android staging proof: " + checks + " assertions passed (host JSON parser, not provider/device)");
    }
}
