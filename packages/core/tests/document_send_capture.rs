#![cfg(feature = "http")]
use localsend::http::{
    server::{
        ServerConfigV2, ServerHandle, directories::DocumentResponse, start_with_port,
        v2::ServerEventV2, web::WebConfig,
    },
    state::ClientInfo,
};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokio::sync::{mpsc, oneshot};
const WS: &str = "11111111-1111-4111-8111-111111111111";
const FILE: &str = "22222222-2222-4222-8222-222222222222";
const SECOND: &str = "33333333-3333-4333-8333-333333333333";
static TESTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);
struct Fixture {
    server: ServerHandle,
    root: PathBuf,
    names: Arc<Mutex<(String, String)>>,
    seen: Arc<Mutex<Vec<Value>>>,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let root = std::env::temp_dir().join(format!("legna-doc-capture-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("first"), b"original document bytes").unwrap();
        std::fs::write(root.join("second"), "第二个文件".as_bytes()).unwrap();
        let names: Arc<Mutex<(String,String)>> = Arc::new(Mutex::new(("文件.txt".into(), "second.txt".into())));
        let names2 = names.clone();
        let base = root.clone();
        let seen = Arc::new(Mutex::new(vec![]));
        let events = seen.clone();
        let (tx, mut rx) = mpsc::channel(32);
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                if let ServerEventV2::DirectoryDocument { request, result_tx } = event {
                    let q: Value = serde_json::from_str(&request).unwrap();
                    events.lock().unwrap().push(q.clone());
                    assert_eq!(q["tree"], "content://capture/tree/root");
                    assert_eq!(q["workspaceId"], WS);
                    assert!(uuid::Uuid::parse_str(q["owner"].as_str().unwrap()).is_ok());
                    let result = match q["op"].as_str().unwrap() {
                        "probe" => Ok(DocumentResponse {
                            payload: json!({"version":1,"readable":true}).to_string(),
                            file: None,
                        }),
                        "close" => Ok(DocumentResponse {
                            payload: "{}".into(),
                            file: None,
                        }),
                        "open" => {
                            let (path, name) = if q["documentId"] == FILE {
                                (base.join("first"), names2.lock().unwrap().0.clone())
                            } else if q["documentId"] == SECOND {
                                (base.join("second"), names2.lock().unwrap().1.clone())
                            } else {
                                let _ = result_tx.send(Err("not_found".into()));
                                continue;
                            };
                            match std::fs::File::open(path){Ok(file)=>Ok(DocumentResponse{payload:json!({"version":1,"id":q["documentId"],"name":name,"size":file.metadata().unwrap().len(),"seekable":true,"mime":"text/plain"}).to_string(),file:Some(file)}),Err(_)=>Err("not_found".into())}
                        }
                        other => panic!("unexpected {other}"),
                    };
                    let _ = result_tx.send(result);
                }
            }
        });
        let (stop, stopped) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "capture".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "fixture".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: false,
                event_tx: tx,
            }),
            WebConfig::default(),
            stopped,
        )
        .await
        .unwrap();
        server.configure_directory_workspaces(&json!({"revision":1,"enabled":true,"workspaces":[{"id":WS,"name":"Documents","slug":"documents","root":"","documentTree":"content://capture/tree/root","generation":1,"visible":true,"allowUpload":false}]}).to_string()).await.unwrap();
        Self {
            server,
            root,
            names,
            seen,
            stop: Some(stop),
        }
    }
    fn stage(&self, name: &str) -> String {
        let path = self.root.join(name);
        std::fs::create_dir(&path).unwrap();
        path.to_str().unwrap().into()
    }
    async fn capture(&self, files: Value, stage: String) -> anyhow::Result<String> {
        self.server
            .capture_workspace_sources(
                WS,
                1,
                &json!({"mode":"documentSnapshot","files":files}).to_string(),
                stage,
            )
            .await
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[tokio::test]
async fn document_snapshot_copies_verified_bytes_and_preserves_the_owned_manifest() {
    let _slot = TESTS.acquire().await.unwrap();
    let f = Fixture::new().await;
    let stage = f.stage("stage");
    let result: Value = serde_json::from_str(
        &f.capture(json!([{"id":FILE},{"id":SECOND}]), stage.clone())
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["files"].as_array().unwrap().len(), 2);
    assert_eq!(result["files"][0]["name"], "文件.txt");
    for (i, original) in ["first", "second"].iter().enumerate() {
        let bytes = std::fs::read(f.root.join(original)).unwrap();
        assert_eq!(
            std::fs::read(PathBuf::from(&stage).join(format!("source-{i}"))).unwrap(),
            bytes
        );
        assert_eq!(result["files"][i]["size"], bytes.len());
        assert_eq!(
            result["files"][i]["sha256"],
            localsend::crypto::hash::sha256_hex(&bytes)
        );
    }
    assert!(!result.to_string().contains("content://"));
    assert!(!result.to_string().contains(f.root.to_str().unwrap()));
    let copied = std::fs::read(PathBuf::from(&stage).join("source-0")).unwrap();
    std::fs::write(f.root.join("first"), b"provider now changed").unwrap();
    assert_eq!(
        std::fs::read(PathBuf::from(&stage).join("source-0")).unwrap(),
        copied
    );
    assert!(
        f.capture(json!([{"id":FILE}]), stage.clone())
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read(PathBuf::from(&stage).join("source-0")).unwrap(),
        copied
    );
}
#[tokio::test]
async fn explicit_document_mode_rejects_versions_duplicates_unsafe_names_and_cleans_partial_capture()
 {
    let _slot = TESTS.acquire().await.unwrap();
    let f = Fixture::new().await;
    for (index, files) in [
        json!([]),
        json!([{"id":FILE,"version":"fake"}]),
        json!([{"id":FILE},{"id":FILE}]),
        json!([{"id":"../../native"}]),
    ]
    .into_iter()
    .enumerate()
    {
        assert!(
            f.capture(files, f.stage(&format!("invalid{index}")))
                .await
                .is_err()
        );
    }
    assert!(!f.seen.lock().unwrap().iter().any(|q| q["op"] == "open"));
    let stage = f.stage("duplicate");
    *f.names.lock().unwrap() = ("same.txt".into(), "SAME.TXT".into());
    assert!(
        f.capture(json!([{"id":FILE},{"id":SECOND}]), stage.clone())
            .await
            .is_err()
    );
    assert_eq!(std::fs::read_dir(stage).unwrap().count(), 0);
    let stage = f.stage("missing");
    std::fs::write(PathBuf::from(&stage).join("unknown.keep"), b"user content").unwrap();
    *f.names.lock().unwrap() = ("safe.txt".into(), "next.txt".into());
    std::fs::remove_file(f.root.join("second")).unwrap();
    assert!(
        f.capture(json!([{"id":FILE},{"id":SECOND}]), stage.clone())
            .await
            .is_err()
    );
    assert_eq!(std::fs::read_dir(&stage).unwrap().count(), 1);
    assert_eq!(
        std::fs::read(PathBuf::from(&stage).join("unknown.keep")).unwrap(),
        b"user content"
    );
    for (i, name) in ["../outside", "a/b", "a\\b", "CON", "bad:", "x.ls", "a?b"]
        .iter()
        .enumerate()
    {
        f.names.lock().unwrap().0 = (*name).into();
        assert!(
            f.capture(json!([{"id":FILE}]), f.stage(&format!("unsafe{i}")))
                .await
                .is_err()
        );
    }
    assert!(
        f.server
            .capture_workspace_sources(
                WS,
                1,
                &json!([{"id":FILE,"version":"fake"}]).to_string(),
                f.stage("legacy")
            )
            .await
            .is_err()
    );
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn workspace_close_stops_actual_copy_and_returns_only_after_owned_output_cleanup() {
    use std::time::Duration;
    let _slot = TESTS.acquire().await.unwrap();
    let f = Fixture::new().await;
    std::fs::File::create(f.root.join("first"))
        .unwrap()
        .set_len(1 << 30)
        .unwrap();
    let stage = f.stage("cancelled");
    let capture = f.capture(json!([{"id":FILE}]), stage.clone());
    let cancel = async {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if std::fs::metadata(PathBuf::from(&stage).join("source-0"))
                    .is_ok_and(|m| m.len() > 0)
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        f.server
            .configure_directory_workspaces(
                &json!({"revision":2,"enabled":true,"workspaces":[]}).to_string(),
            )
            .await
            .unwrap();
    };
    let (result, ()) = tokio::join!(capture, cancel);
    assert!(result.is_err());
    assert_eq!(std::fs::read_dir(stage).unwrap().count(), 0);
}
