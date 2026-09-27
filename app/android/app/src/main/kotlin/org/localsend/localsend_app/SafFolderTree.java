package org.localsend.localsend_app;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Original-v2 folder selection metadata. Never interprets an opaque document ID. */
final class SafFolderTree {
    static final int MAX_ENTRIES = 20000, MAX_DEPTH = 64, MAX_BYTES = 16 * 1024 * 1024;
    static final class Failure extends IOException {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    static final class Node {
        final String id, name, uri;
        final boolean directory, virtual;
        final Long size, modified;
        Node(String id, String name, String uri, boolean directory, boolean virtual, Long size, Long modified) {
            this.id=id; this.name=name; this.uri=uri; this.directory=directory; this.virtual=virtual; this.size=size; this.modified=modified;
        }
    }
    interface Rows extends AutoCloseable {
        Node next() throws Exception;
        @Override void close();
    }
    interface Provider {
        Node root() throws Exception;
        Rows children(Node parent) throws Exception;
        void check() throws Exception;
    }
    static final class File {
        final Node node; final String relativePath;
        File(Node node,String relativePath) { this.node=node;this.relativePath=relativePath; }
    }
    static final class Result {
        final List<File> files = new ArrayList<>();
        int emptyDirectories, entries, bytes;
    }
    private static final class Pending {
        final Node node; final String path; final int depth;
        Pending(Node node,String path,int depth) {this.node=node;this.path=path;this.depth=depth;}
    }
    static String name(String name) throws Failure {
        if(name==null||name.isEmpty()||name.equals(".")||name.equals("..")||name.getBytes(StandardCharsets.UTF_8).length>255)
            throw new Failure("invalid_name");
        for(int i=0;i<name.length();i++) if(name.charAt(i)<32||name.charAt(i)==127||name.charAt(i)=='/'||name.charAt(i)=='\\')
            throw new Failure("invalid_name");
        return name;
    }
    static Result read(Provider provider) throws Exception {
        provider.check(); Node root=provider.root();
        if(root==null||!root.directory)throw new Failure("unsupported");
        Result result=new Result(); ArrayDeque<Pending> pending=new ArrayDeque<>();
        pending.add(new Pending(root,name(root.name),0));
        Set<String> ids=new HashSet<>(), paths=new HashSet<>();ids.add(root.id);paths.add(root.name);
        while(!pending.isEmpty()) {
            provider.check();Pending parent=pending.removeLast();boolean empty=true;
            try(Rows rows=provider.children(parent.node)) {
                for(;;) {
                    provider.check();Node node=rows.next();if(node==null)break;empty=false;
                    if(++result.entries>MAX_ENTRIES)throw new Failure("limit");
                    if(node.id==null||node.id.isEmpty()||node.id.length()>8192||!ids.add(node.id))throw new Failure("duplicate");
                    String path=parent.path+"/"+name(node.name);
                    if(path.getBytes(StandardCharsets.UTF_8).length>4096||parent.depth+1>MAX_DEPTH)throw new Failure("limit");
                    if(!paths.add(path))throw new Failure("duplicate");
                    if(node.uri==null||node.uri.length()>16384)throw new Failure("invalid");
                    // Includes conservative retained strings, set keys, rows and channel copies.
                    result.bytes+=256+4*(path.length()+node.id.length()+node.name.length()+node.uri.length());
                    if(result.bytes>MAX_BYTES)throw new Failure("limit");
                    if(node.directory)pending.add(new Pending(node,path,parent.depth+1));
                    else {
                        if(node.virtual||node.size==null||node.size<0||node.size>9007199254740991L)throw new Failure("unsupported");
                        result.files.add(new File(node,path));
                    }
                }
            }
            if(empty)result.emptyDirectories++;
        }
        provider.check();return result;
    }
}
