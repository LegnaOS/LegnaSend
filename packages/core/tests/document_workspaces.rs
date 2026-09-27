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
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};
const WS: &str = "11111111-1111-4111-8111-111111111111";
const FOLDER: &str = "22222222-2222-4222-8222-222222222222";
const FILE: &str = "33333333-3333-4333-8333-333333333333";
const NESTED_FILE: &str = "66666666-6666-4666-8666-666666666666";
const EMPTY: &str = "77777777-7777-4777-8777-777777777777";
const UNKNOWN: &str = "44444444-4444-4444-8444-444444444444";
struct Fixture {
    server: ServerHandle,
    client: reqwest::Client,
    url: String,
    temp: PathBuf,
    events: Arc<Mutex<Vec<Value>>>,
    watch_revision: Arc<std::sync::atomic::AtomicU64>,
    stop: Option<oneshot::Sender<()>>,
}
impl Fixture {
    async fn new() -> Self {
        let temp =
            std::env::temp_dir().join(format!("legna-doc-provider-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&temp).unwrap();
        std::fs::write(temp.join("data"), b"document bytes").unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let seen = events.clone();
        let source = temp.join("data");
        let watch_revision = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let revision = watch_revision.clone();
        let (tx, mut rx) = mpsc::channel(16);
        tokio::spawn(async move {
            let mut used_cursor = false;
            while let Some(event) = rx.recv().await {
                if let ServerEventV2::DirectoryDocument { request, result_tx } = event {
                    let request: Value = serde_json::from_str(&request).unwrap();
                    seen.lock().unwrap().push(request.clone());
                    assert_eq!(request["tree"], "content://fixture/tree/root");
                    let response = match request["op"].as_str().unwrap() {
                        "probe" => Ok(DocumentResponse {
                            payload: json!({"version":1,"readable":true}).to_string(),
                            file: None,
                        }),
                        "close" => Ok(DocumentResponse {
                            payload: "{}".into(),
                            file: None,
                        }),
                        "state" => {
                            if !["", FOLDER, EMPTY]
                                .contains(&request["documentId"].as_str().unwrap())
                            {
                                Err("not_found".into())
                            } else {
                                Ok(DocumentResponse {payload: json!({"version":1,"watchId":"88888888-8888-4888-8888-888888888888","revision":revision.load(std::sync::atomic::Ordering::SeqCst),"observing":true}).to_string(),file:None})
                            }
                        }
                        "list" => {
                            let id = request["documentId"].as_str().unwrap();
                            if !["", FOLDER, EMPTY].contains(&id) {
                                Err("not_found".into())
                            } else {
                                let second =
                                    request["cursor"] == "55555555-5555-4555-8555-555555555555:2";
                                if !second && id.is_empty() {
                                    used_cursor = false;
                                }
                                if second && used_cursor {
                                    let _ = result_tx.send(Err("expired".into()));
                                    continue;
                                }
                                if second {
                                    used_cursor = true;
                                }
                                let entries = if second {
                                    vec![
                                        json!({"id":UNKNOWN,"name":"unknown.bin","directory":false,"size":null}),
                                    ]
                                } else if id == EMPTY {
                                    vec![]
                                } else if id == FOLDER {
                                    vec![
                                        json!({"id":NESTED_FILE,"name":"文件.txt","directory":false,"size":14,"downloadable":true}),
                                        json!({"id":EMPTY,"name":"空目录","directory":true,"size":null,"downloadable":false}),
                                    ]
                                } else {
                                    vec![
                                        json!({"id":FOLDER,"name":"子目录","directory":true,"size":null}),
                                        json!({"id":FILE,"name":"文件.txt","directory":false,"size":14,"downloadable":true}),
                                    ]
                                };
                                Ok(DocumentResponse{payload:json!({"version":1,"entries":entries,"cursor":if second||id==FOLDER||id==EMPTY{None}else{Some("55555555-5555-4555-8555-555555555555:2")},"offset":if second{2}else{0},"scanned":if id==EMPTY{0}else if second{1}else{2}}).to_string(),file:None})
                            }
                        }
                        "open" => {
                            if request["documentId"] != FILE && request["documentId"] != NESTED_FILE
                            {
                                Err("unsupported".into())
                            } else {
                                Ok(DocumentResponse{payload:json!({"version":1,"id":request["documentId"],"name":"文件.txt","size":14,"seekable":true,"mime":"text/plain"}).to_string(),file:Some(std::fs::File::open(&source).unwrap())})
                            }
                        }
                        _ => Err("invalid".into()),
                    };
                    let _ = result_tx.send(response);
                }
            }
        });
        let (stop, stop_rx) = oneshot::channel();
        let server = start_with_port(
            0,
            None,
            ClientInfo {
                alias: "documents test".into(),
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
            stop_rx,
        )
        .await
        .unwrap();
        Self {
            url: format!("http://127.0.0.1:{}", server.port()),
            server,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
            temp,
            events,
            watch_revision,
            stop: Some(stop),
        }
    }
    fn config(&self) -> Value {
        json!({"id":WS,"name":"Documents","slug":"documents","root":"","documentTree":"content://fixture/tree/root","generation":1,"visible":true,"allowUpload":false})
    }
    async fn configure(&self, revision: u64, entries: Vec<Value>) -> anyhow::Result<String> {
        self.server
            .configure_directory_workspaces(
                &json!({"revision":revision,"enabled":true,"workspaces":entries}).to_string(),
            )
            .await
    }
    fn archive(&self, params: &[(&str, &str)]) -> String {
        let query = form_urlencoded::Serializer::new(String::new())
            .extend_pairs(params.iter().copied())
            .finish();
        self.path(&format!("archive?{query}"))
    }
    fn path(&self, suffix: &str) -> String {
        format!("{}/api/legnasend/v1/workspaces/{WS}/{suffix}", self.url)
    }
    async fn close(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.server.wait_stopped().await;
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.take();
        let _ = std::fs::remove_dir_all(&self.temp);
    }
}

#[tokio::test]
async fn document_index_opaque_navigation_pagination_and_single_request_download() {
    let f = Fixture::new().await;
    f.configure(1, vec![f.config()]).await.unwrap();
    let index: Value = f
        .client
        .get(format!("{}/api/legnasend/v1/workspaces", f.url))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let meta = &index["workspaces"][0];
    assert_eq!(meta["backend"], "documents");
    assert_eq!(meta["capabilities"]["resume"], false);
    assert!(meta.get("documentTree").is_none());
    assert_eq!(meta["allowUpload"], false);
    let first: Value = f
        .client
        .get(f.path("files?generation=1"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(first["entries"][0]["id"], FOLDER);
    assert_eq!(first["entries"][1]["downloadable"], true);
    let next: Value = f
        .client
        .get(f.path("files?generation=1&cursor=55555555-5555-4555-8555-555555555555:2"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(next["entries"][0]["size"].is_null());
    assert_eq!(next["entries"][0]["downloadable"], false);
    assert_eq!(
        f.client
            .get(f.path("files?generation=1&cursor=55555555-5555-4555-8555-555555555555:2"))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let nested: Value = f
        .client
        .get(f.path(&format!("files?generation=1&path={FOLDER}")))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(nested["entries"][0]["name"], "文件.txt");
    let response = f
        .client
        .get(f.path(&format!("files/{FILE}/content?generation=1")))
        .header("Range", "bytes=2-4")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["accept-ranges"], "none");
    assert!(response.headers().get("etag").is_none());
    assert_eq!(
        response.bytes().await.unwrap(),
        b"document bytes".as_slice()
    );
    assert_eq!(
        f.client
            .get(f.path(&format!("files/{FILE}/content?generation=1")))
            .header("If-Match", "\"old\"")
            .send()
            .await
            .unwrap()
            .status(),
        412
    );
    for suffix in [
        format!("files/{UNKNOWN}/content?generation=1"),
        "archive?generation=1".into(),
        "events?generation=1".into(),
    ] {
        assert_eq!(
            f.client.get(f.path(&suffix)).send().await.unwrap().status(),
            501
        );
    }
    assert_eq!(
        f.client
            .get(f.path("files?generation=1&path=../../escape"))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    f.configure(2, vec![]).await.unwrap();
    for _ in 0..100 {
        if f.events.lock().unwrap().iter().any(|e| e["op"] == "close") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        f.events
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["op"] == "close" && e["workspaceId"] == WS && e["generation"] == 1)
    );
    f.close().await;
}

#[tokio::test]
async fn document_permission_stays_behind_workspace_password_and_backend_never_falls_back_to_root()
{
    let f = Fixture::new().await;
    let mut invalid = f.config();
    invalid["root"] = json!(f.temp);
    assert!(f.configure(1, vec![invalid]).await.is_err());
    let mut config = f.config();
    config["passwordHash"] = json!(
        localsend::http::server::directory_auth::hash_password("1234".into())
            .await
            .unwrap()
    );
    f.configure(2, vec![config]).await.unwrap();
    assert_eq!(
        f.client
            .get(f.path("files?generation=1"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        f.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["op"] == "list")
            .count(),
        0
    );
    let login = f
        .client
        .post(f.path("unlock"))
        .header("Content-Type", "application/json")
        .body(json!({"password":"1234","generation":1}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(login.status(), 200);
    let cookie = login.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap();
    assert_eq!(
        f.client
            .get(f.path("files?generation=1"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        f.client
            .post(f.path("upload?generation=1"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    f.close().await;
}

fn zip_files(bytes: &[u8]) -> std::collections::HashMap<String, Vec<u8>> {
    fn u16(b: &[u8], i: usize) -> usize {
        u16::from_le_bytes(b[i..i + 2].try_into().unwrap()) as usize
    }
    fn u32(b: &[u8], i: usize) -> u32 {
        u32::from_le_bytes(b[i..i + 4].try_into().unwrap())
    }
    fn u64(b: &[u8], i: usize) -> u64 {
        u64::from_le_bytes(b[i..i + 8].try_into().unwrap())
    }
    let mut offset = 0;
    let mut result = std::collections::HashMap::new();
    let mut starts = std::collections::HashMap::new();
    while u32(bytes, offset) == 0x04034b50 {
        let n = u16(bytes, offset + 26);
        let extra = u16(bytes, offset + 28);
        assert_eq!(u16(bytes, offset + 8), 0);
        assert_eq!(u16(bytes, offset + 6), 0x808);
        let name = String::from_utf8(bytes[offset + 30..offset + 30 + n].to_vec()).unwrap();
        let size = u64(bytes, offset + 30 + n + 4) as usize;
        starts.insert(name.clone(), offset as u64);
        offset += 30 + n + extra;
        let content = bytes[offset..offset + size].to_vec();
        offset += size;
        assert_eq!(u32(bytes, offset), 0x08074b50);
        assert_eq!(u32(bytes, offset + 4), crc32fast::hash(&content));
        assert_eq!(u64(bytes, offset + 8), size as u64);
        assert_eq!(u64(bytes, offset + 16), size as u64);
        offset += 24;
        assert!(result.insert(name, content).is_none());
    }
    let central_start = offset;
    let mut count = 0;
    while u32(bytes, offset) == 0x02014b50 {
        let n = u16(bytes, offset + 28);
        let extra = u16(bytes, offset + 30);
        let name = String::from_utf8(bytes[offset + 46..offset + 46 + n].to_vec()).unwrap();
        assert_eq!(u32(bytes, offset + 16), crc32fast::hash(&result[&name]));
        assert_eq!(u64(bytes, offset + 46 + n + 20), starts[&name]);
        offset += 46 + n + extra;
        count += 1;
    }
    assert_eq!(count, result.len());
    assert_eq!(u32(bytes, offset), 0x06064b50);
    assert_eq!(u64(bytes, offset + 32), count as u64);
    assert_eq!(u64(bytes, offset + 40), (offset - central_start) as u64);
    assert_eq!(u64(bytes, offset + 48), central_start as u64);
    assert_eq!(u32(bytes, offset + 56), 0x07064b50);
    assert_eq!(u32(bytes, offset + 76), 0x06054b50);
    assert_eq!(offset + 98, bytes.len());
    result
}

#[tokio::test]
async fn document_selected_zip_preserves_unicode_empty_directories_and_refuses_other_parents() {
    let f = Fixture::new().await;
    f.configure(1, vec![f.config()]).await.unwrap();
    let ids = serde_json::to_string(&vec![FOLDER]).unwrap();
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("path", ""), ("ids", &ids)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["accept-ranges"], "none");
    let entries = zip_files(&response.bytes().await.unwrap());
    assert_eq!(entries["files/子目录/文件.txt"], b"document bytes");
    assert!(entries["files/子目录/空目录/"].is_empty());
    assert!(!entries.contains_key("files/文件.txt"));
    assert!(!entries.keys().any(|name| name.contains(FOLDER)));
    let ids = serde_json::to_string(&vec![FILE]).unwrap();
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("path", FOLDER), ("ids", &ids)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 404);
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("path", FOLDER)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let entries = zip_files(&response.bytes().await.unwrap());
    assert_eq!(entries["files/文件.txt"], b"document bytes");
    assert!(entries.contains_key("files/空目录/"));
    f.close().await;
}

#[tokio::test]
async fn filesystem_selected_zip_keeps_parent_membership_and_streams_only_selected_subtree() {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let f = Fixture::new().await;
    std::fs::create_dir_all(f.temp.join("nested/empty")).unwrap();
    std::fs::write(f.temp.join("nested/中文.txt"), b"original").unwrap();
    let mut config = f.config();
    config.as_object_mut().unwrap().remove("documentTree");
    config["root"] = json!(f.temp);
    f.configure(1, vec![config]).await.unwrap();
    let id = URL_SAFE_NO_PAD.encode("nested");
    let ids = serde_json::to_string(&vec![id.clone()]).unwrap();
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("path", ""), ("ids", &ids)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let entries = zip_files(&response.bytes().await.unwrap());
    assert_eq!(entries["files/nested/中文.txt"], b"original");
    assert!(entries.contains_key("files/nested/empty/"));
    assert!(!entries.contains_key("files/data"));
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("path", "nested"), ("ids", &ids)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 400);
    let ids = serde_json::to_string(&vec![id.clone(), id]).unwrap();
    let response = f
        .client
        .get(f.archive(&[("generation", "1"), ("ids", &ids)]))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 400);
    f.close().await;
}

#[tokio::test]
async fn document_preview_lease_ranges_close_and_generation_revocation_use_same_open_file() {
    let f = Fixture::new().await;
    f.configure(1, vec![f.config()]).await.unwrap();
    let prepare = f
        .client
        .post(f.path("prepare-preview?generation=1"))
        .json(&json!({"id":FILE}))
        .send()
        .await
        .unwrap();
    assert_eq!(prepare.status(), 200);
    let preview: Value = prepare.json().await.unwrap();
    let url = format!("{}{}", f.url, preview["url"].as_str().unwrap());
    let head = f.client.head(&url).send().await.unwrap();
    assert_eq!(head.status(), 200);
    assert_eq!(head.headers()["etag"], preview["etag"].as_str().unwrap());
    for (range, expected) in [
        ("bytes=0-7", b"document".as_slice()),
        ("bytes=9-13", b"bytes".as_slice()),
    ] {
        let response = f
            .client
            .get(&url)
            .header("Range", range)
            .header("If-Match", preview["etag"].as_str().unwrap())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 206);
        assert_eq!(response.bytes().await.unwrap(), expected);
    }
    assert_eq!(
        f.events
            .lock()
            .unwrap()
            .iter()
            .filter(|event| event["op"] == "open")
            .count(),
        1
    );
    let close = f
        .client
        .post(f.path("close-preview?generation=1"))
        .json(&json!({"lease":preview["lease"]}))
        .send()
        .await
        .unwrap();
    assert_eq!(close.status(), 200);
    assert_eq!(f.client.get(&url).send().await.unwrap().status(), 410);
    let second: Value = f
        .client
        .post(f.path("prepare-preview?generation=1"))
        .json(&json!({"id":FILE}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let mut config = f.config();
    config["generation"] = json!(2);
    f.configure(2, vec![config]).await.unwrap();
    assert_eq!(
        f.client
            .get(format!("{}{}", f.url, second["url"].as_str().unwrap()))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    let updated = second["url"]
        .as_str()
        .unwrap()
        .replace("generation=1", "generation=2");
    assert_eq!(
        f.client
            .get(format!("{}{updated}", f.url))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    f.close().await;
}

#[tokio::test]
async fn bearer_document_preview_and_archive_keep_scope_actor_and_revocation_guards() {
    use localsend::http::server::integration::{
        ApiConfig, Limits, PREFIX, Scope, WorkspaceGrant, create_key,
    };
    let f = Fixture::new().await;
    f.configure(1, vec![f.config()]).await.unwrap();
    let key = create_key(
        "preview".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Files],
            workspaces: vec![WS.into()],
        },
        None,
    )
    .unwrap();
    let other = create_key(
        "other".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Files],
            workspaces: vec![WS.into()],
        },
        None,
    )
    .unwrap();
    let denied = create_key(
        "no read".into(),
        WorkspaceGrant {
            scopes: vec![Scope::Service],
            workspaces: vec![WS.into()],
        },
        None,
    )
    .unwrap();
    let mut config = ApiConfig {
        revision: 1,
        enabled: true,
        global_limits: Limits {
            per_second: 1000,
            per_minute: 60000,
            concurrent: 16,
        },
        key_limits: Limits {
            per_second: 1000,
            per_minute: 60000,
            concurrent: 8,
        },
        keys: vec![
            key.record.clone(),
            other.record.clone(),
            denied.record.clone(),
        ],
        ..ApiConfig::default()
    };
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    let base = format!("{}{PREFIX}/workspaces/{WS}", f.url);
    let response = f
        .client
        .post(format!("{base}/prepare-preview?generation=1"))
        .bearer_auth(&denied.secret)
        .json(&json!({"id":FILE}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 403);
    let response = f
        .client
        .post(format!("{base}/prepare-preview?generation=1"))
        .bearer_auth(&key.secret)
        .json(&json!({"id":FILE}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let preview: Value = response.json().await.unwrap();
    assert!(
        preview["url"]
            .as_str()
            .unwrap()
            .starts_with(&format!("{PREFIX}/workspaces/"))
    );
    let url = format!("{}{}", f.url, preview["url"].as_str().unwrap());
    assert_eq!(f.client.head(&url).send().await.unwrap().status(), 401);
    assert_eq!(
        f.client
            .head(&url)
            .bearer_auth(&other.secret)
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let response = f
        .client
        .get(&url)
        .bearer_auth(&key.secret)
        .header("Range", "bytes=0-7")
        .header("If-Match", preview["etag"].as_str().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(response.bytes().await.unwrap(), b"document".as_slice());
    let closed = f
        .client
        .post(format!("{base}/close-preview?generation=1"))
        .bearer_auth(&key.secret)
        .json(&json!({"lease":preview["lease"]}))
        .send()
        .await
        .unwrap();
    assert_eq!(closed.status(), 200);
    assert_eq!(
        f.client
            .head(&url)
            .bearer_auth(&key.secret)
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    let ids = json!([FILE]).to_string();
    let archive = f
        .client
        .get(format!(
            "{base}/archive?{}",
            form_urlencoded::Serializer::new(String::new())
                .append_pair("generation", "1")
                .append_pair("ids", &ids)
                .finish()
        ))
        .bearer_auth(&key.secret)
        .send()
        .await
        .unwrap();
    assert_eq!(archive.status(), 200);
    let zipped = zip_files(&archive.bytes().await.unwrap());
    assert_eq!(zipped.get("files/文件.txt").unwrap(), b"document bytes");
    let response = f
        .client
        .post(format!("{base}/prepare-preview?generation=1"))
        .bearer_auth(&key.secret)
        .json(&json!({"id":FILE}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let preview: Value = response.json().await.unwrap();
    let url = format!("{}{}", f.url, preview["url"].as_str().unwrap());
    config.revision = 2;
    config.keys.remove(0);
    f.server
        .configure_integration_api(&serde_json::to_string(&config).unwrap())
        .await
        .unwrap();
    assert_eq!(
        f.client
            .head(&url)
            .bearer_auth(&key.secret)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            let status = f
                .client
                .head(&url)
                .bearer_auth(&other.secret)
                .send()
                .await
                .unwrap()
                .status();
            if status == 410 {
                break;
            }
            assert_eq!(status, 403);
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    f.close().await;
}

#[tokio::test]
async fn document_state_has_independent_scoped_invalidation_without_claiming_file_versions() {
    let f = Fixture::new().await;
    f.configure(1, vec![f.config()]).await.unwrap();
    let get = || f.client.get(f.path("state?generation=1"));
    let first: Value = get().send().await.unwrap().json().await.unwrap();
    assert_eq!(first["refreshFromStart"], true);
    assert_eq!(first["observing"], true);
    assert_eq!(first["generation"], 1);
    assert_eq!(first["path"], "");
    assert!(first.get("entries").is_none());
    assert!(first.get("etag").is_none());
    assert_eq!(first["stamp"], "88888888-8888-4888-8888-888888888888:0");
    let stable: Value = get().send().await.unwrap().json().await.unwrap();
    assert_eq!(stable, first);
    f.watch_revision
        .store(1, std::sync::atomic::Ordering::SeqCst);
    let changed: Value = get().send().await.unwrap().json().await.unwrap();
    assert_eq!(changed["watchId"], first["watchId"]);
    assert_ne!(changed["stamp"], first["stamp"]);
    for (query, status) in [
        ("generation=2", 409),
        ("generation=1&path=../../escape", 400),
        (
            "generation=1&path=99999999-9999-4999-8999-999999999999",
            404,
        ),
        ("generation=1&ids=not-a-file-version", 400),
    ] {
        assert_eq!(
            f.client
                .get(f.path(&format!("state?{query}")))
                .send()
                .await
                .unwrap()
                .status(),
            status
        );
    }
    let seen = f.events.lock().unwrap();
    let states: Vec<_> = seen.iter().filter(|v| v["op"] == "state").collect();
    assert!(states.len() >= 3);
    assert!(states.iter().all(|v| v["workspaceId"] == WS
        && v["generation"] == 1
        && uuid::Uuid::parse_str(v["owner"].as_str().unwrap()).is_ok()));
}
