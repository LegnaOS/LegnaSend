package org.localsend.localsend_app;

import java.util.*;

public final class SafFolderTreeTest {
    static SafFolderTree.Node node(String id,String name,boolean dir,Long size) {
        return new SafFolderTree.Node(id,name,"content://opaque/tree/grant/document/"+id,dir,false,size,null);
    }
    static final class Source implements SafFolderTree.Provider {
        Map<String,List<SafFolderTree.Node>> rows=new HashMap<>();
        int closed,checks;boolean fail,cancel;
        public SafFolderTree.Node root(){return node("opaque-root-391","頂層",true,null);}
        public void check() throws Exception {if(cancel)throw new SafFolderTree.Failure("cancelled");checks++;}
        public SafFolderTree.Rows children(SafFolderTree.Node parent) {
            Iterator<SafFolderTree.Node> iterator=rows.getOrDefault(parent.id,Collections.emptyList()).iterator();
            return new SafFolderTree.Rows(){
                public SafFolderTree.Node next() throws Exception {if(fail)throw new SafFolderTree.Failure("unavailable");return iterator.hasNext()?iterator.next():null;}
                public void close(){closed++;}
            };
        }
    }
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    static void failure(Source source,String code) throws Exception {
        try{SafFolderTree.read(source);throw new AssertionError("accepted "+code);}
        catch(SafFolderTree.Failure error){check(error.code.equals(code));}
    }
    public static void main(String[] args) throws Exception {
        Source source=new Source();source.rows.put("opaque-root-391",Arrays.asList(node("xyz", "資料",true,null),node("no-path-id", "空目錄",true,null)));
        source.rows.put("xyz",Arrays.asList(node("no-parent-or-name-here","中文 %.txt",false,7L)));
        SafFolderTree.Result result=SafFolderTree.read(source);
        check(result.files.size()==1&&result.files.get(0).relativePath.equals("頂層/資料/中文 %.txt"));
        check(result.emptyDirectories==1&&source.closed==3);
        Source many=new Source();List<SafFolderTree.Node> files=new ArrayList<>();
        for(int i=0;i<5000;i++)files.add(node("opaque"+i,"文件"+i,false,(long)i));many.rows.put("opaque-root-391",files);
        result=SafFolderTree.read(many);check(result.files.size()==5000&&result.bytes<=SafFolderTree.MAX_BYTES&&many.closed==1);
        Source unknown=new Source();unknown.rows.put("opaque-root-391",Arrays.asList(node("one","ok",false,3L),node("two","unknown",false,null)));failure(unknown,"unsupported");check(unknown.closed==1);
        Source duplicate=new Source();duplicate.rows.put("opaque-root-391",Arrays.asList(node("one","same",false,3L),node("two","same",false,3L)));failure(duplicate,"duplicate");
        Source cycle=new Source();cycle.rows.put("opaque-root-391",Collections.singletonList(node("opaque-root-391","again",true,null)));failure(cycle,"duplicate");
        Source bad=new Source();bad.rows.put("opaque-root-391",Collections.singletonList(node("bad","../escape",false,0L)));failure(bad,"invalid_name");
        Source denied=new Source();denied.fail=true;failure(denied,"unavailable");check(denied.closed==1);
        Source cancelled=new Source();cancelled.cancel=true;failure(cancelled,"cancelled");check(cancelled.closed==0);
        Source budget=new Source();List<SafFolderTree.Node> huge=new ArrayList<>();for(int i=0;i<=SafFolderTree.MAX_ENTRIES;i++)huge.add(node("x"+i,"f"+i,false,1L));budget.rows.put("opaque-root-391",huge);failure(budget,"limit");check(budget.closed==1);
        Source virtual=new Source();virtual.rows.put("opaque-root-391",Collections.singletonList(new SafFolderTree.Node("v","virtual","content://opaque/v",false,true,0L,null)));failure(virtual,"unsupported");
        System.out.println("PASS opaque nesting, 5000 files, empty count, unknown size atomic failure, duplicate, cycle, traversal, query failure, cancellation, limit, virtual");
    }
}
