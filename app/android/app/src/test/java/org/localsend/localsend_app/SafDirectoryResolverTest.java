package org.localsend.localsend_app;

import java.io.IOException;
import java.util.*;

/** Runs on the JDK without Gradle/network; Android adapter is separately SDK-compiled. */
public final class SafDirectoryResolverTest {
    static int checks;
    static final class Fake implements SafDirectoryResolver.Backend {
        final Map<String, SafDirectoryResolver.Document> docs = new HashMap<>();
        final Map<String, Map<String, String>> children = new HashMap<>();
        final List<String> parents = new ArrayList<>();
        boolean granted = true, failedQuery = false, rename = false, createNull = false;
        int creates, grantChecks;
        Fake() { docs.put("id:ROOT", doc("id:ROOT", "Downloads", true, true)); }
        public String writableRoot(String tree) throws IOException {
            grantChecks++;
            if (!granted) throw new SafDirectoryResolver.Failure("PERMISSION_DENIED", "revoked");
            return "id:ROOT";
        }
        public SafDirectoryResolver.Document stat(String uri) { return docs.get(uri); }
        public SafDirectoryResolver.Document findChild(String parent, String name) throws IOException {
            if (failedQuery) throw new SafDirectoryResolver.Failure("DIRECTORY_UNAVAILABLE", "offline");
            String uri = children.getOrDefault(parent, Collections.emptyMap()).get(name);
            return uri == null ? null : docs.get(uri);
        }
        public String createDirectory(String parent, String name) {
            creates++; parents.add(parent);
            if (createNull) return null;
            String id = "provider-key:" + creates;
            docs.put(id, doc(id, rename ? name + " (2)" : name, true, true));
            children.computeIfAbsent(parent, ignored -> new HashMap<>()).put(name, id);
            return id;
        }
    }
    static SafDirectoryResolver.Document doc(String uri, String name, boolean directory, boolean write) {
        return new SafDirectoryResolver.Document(uri, name, directory, write);
    }
    static void eq(Object got, Object expected) { checks++; if (!Objects.equals(got, expected)) throw new AssertionError(got + " != " + expected); }
    interface Work { void run() throws IOException; }
    static void fails(String code, Work work) throws IOException {
        try { work.run(); throw new AssertionError("Expected " + code); }
        catch (SafDirectoryResolver.Failure error) { eq(error.code, code); }
    }
    public static void main(String[] args) throws IOException {
        SafDirectoryResolver.requireCompleteListing(false, false);
        fails("DIRECTORY_UNAVAILABLE", () -> SafDirectoryResolver.requireCompleteListing(true, false));
        fails("DIRECTORY_UNAVAILABLE", () -> SafDirectoryResolver.requireCompleteListing(false, true));
        fails("DIRECTORY_UNAVAILABLE", () -> SafDirectoryResolver.requireCompleteListing(true, true));
        Fake f = new Fake();
        eq(SafDirectoryResolver.resolve(f, "tree", Arrays.asList("中文 %", "second")), "provider-key:2");
        eq(f.parents, Arrays.asList("id:ROOT", "provider-key:1"));
        eq(SafDirectoryResolver.resolve(f, "tree", Arrays.asList("中文 %", "second")), "provider-key:2");
        eq(f.creates, 2); eq(f.grantChecks, 2);
        f.granted = false;
        fails("PERMISSION_DENIED", () -> SafDirectoryResolver.resolve(f, "tree", Arrays.asList("中文 %", "second")));
        eq(f.creates, 2);
        Fake missing = new Fake(); missing.docs.clear();
        fails("DIRECTORY_UNAVAILABLE", () -> SafDirectoryResolver.resolve(missing, "tree", Collections.emptyList()));
        Fake readonly = new Fake(); readonly.docs.put("id:ROOT", doc("id:ROOT", "root", true, false));
        fails("PERMISSION_DENIED", () -> SafDirectoryResolver.resolve(readonly, "tree", Arrays.asList("new")));
        eq(readonly.creates, 0);
        Fake collision = new Fake(); collision.children.put("id:ROOT", Collections.singletonMap("file", "id:FILE"));
        collision.docs.put("id:FILE", doc("id:FILE", "file", false, true));
        fails("NAME_CONFLICT", () -> SafDirectoryResolver.resolve(collision, "tree", Arrays.asList("file")));
        eq(collision.creates, 0);
        Fake offline = new Fake(); offline.failedQuery = true;
        fails("DIRECTORY_UNAVAILABLE", () -> SafDirectoryResolver.resolve(offline, "tree", Arrays.asList("folder")));
        eq(offline.creates, 0);
        Fake renamed = new Fake(); renamed.rename = true;
        fails("NAME_CONFLICT", () -> SafDirectoryResolver.resolve(renamed, "tree", Arrays.asList("folder", "child")));
        eq(renamed.creates, 1);
        Fake nullCreate = new Fake(); nullCreate.createNull = true;
        fails("CREATE_FAILED", () -> SafDirectoryResolver.resolve(nullCreate, "tree", Arrays.asList("folder")));
        for (String name : Arrays.asList("", ".", "..", "a/b", "a\\b", "x\u0000y", "x\ny")) {
            Fake invalid = new Fake();
            fails("INVALID_ARGUMENT", () -> SafDirectoryResolver.resolve(invalid, "tree", Arrays.asList("valid", name)));
            eq(invalid.creates, 0); eq(invalid.grantChecks, 0);
        }
        Fake deep = new Fake();
        fails("INVALID_ARGUMENT", () -> SafDirectoryResolver.resolve(deep, "tree", Collections.nCopies(129, "a")));
        eq(deep.creates, 0);
        System.out.println("SAF resolver: " + checks + " assertions passed");
    }
}
