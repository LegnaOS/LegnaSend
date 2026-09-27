#![cfg(feature = "http")]
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{ServerConfigV2, ServerHandle, start_with_port};
use localsend::http::state::ClientInfo;
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use tokio::sync::{mpsc, oneshot};

// Production has a process-wide bounded writer pool. Keep independent test
// servers below that limit rather than making parallel tests expect no limit.
static FIXTURE_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);

struct Fixture {
    _slot: tokio::sync::SemaphorePermit<'static>,
    dir: PathBuf,
    url: String,
    server: ServerHandle,
    stop: Option<oneshot::Sender<()>>,
    client: reqwest::Client,
    results: mpsc::UnboundedReceiver<Result<(), String>>,
    progress: mpsc::UnboundedReceiver<u64>,
    targets: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    recovered: mpsc::UnboundedReceiver<(String, String, u64, String)>,
}
impl Fixture {
    async fn new(resumable: bool) -> Self {
        Self::with_tls(resumable, false).await
    }
    async fn with_tls(resumable: bool, tls: bool) -> Self {
        Self::with_options(
            resumable,
            tls,
            std::env::var_os("LEGNA_TEST_DESCRIPTOR_RECEIVE").is_some(),
            false,
        )
        .await
    }
    async fn with_options(
        resumable: bool,
        tls: bool,
        provider: bool,
        reject_identity: bool,
    ) -> Self {
        Self::with_storage(resumable, tls, provider, reject_identity, None, None).await
    }
    async fn with_storage(
        resumable: bool,
        tls: bool,
        provider: bool,
        reject_identity: bool,
        directory: Option<PathBuf>,
        recovery_journal: Option<PathBuf>,
    ) -> Self {
        let slot = FIXTURE_SLOTS.acquire().await.unwrap();
        let _ = rustls::crypto::ring::default_provider().install_default();
        let certificate = if tls {
            Some(localsend::crypto::cert::generate_self_signed().unwrap())
        } else {
            None
        };
        let mut client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(10));
        if tls {
            client = client
                .danger_accept_invalid_certs(true)
                .identity(new_identity());
        }
        let client = client.build().unwrap();
        let dir = directory.unwrap_or_else(|| {
            std::env::temp_dir().join(format!("legnasend-cache-http-{}", uuid::Uuid::new_v4()))
        });
        std::fs::create_dir_all(&dir).unwrap();
        let (events, mut rx) = mpsc::channel(16);
        let (results, results_rx) = mpsc::unbounded_channel();
        let (progress, progress_rx) = mpsc::unbounded_channel();
        let (recovered, recovered_rx) = mpsc::unbounded_channel();
        let targets = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let target_count = targets.clone();
        let dest = dir.clone();
        // Run the same HTTP contracts against both existing paths and the
        // provider descriptor/publication boundary, without a private wire format.
        if provider {
            eprintln!("Using provider descriptor receive target");
        }
        tokio::spawn(async move {
            let mut provider_records =
                std::collections::HashMap::<String, (String, PathBuf, PathBuf)>::new();
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let ids = files
                            .keys()
                            .cloned()
                            .collect::<std::collections::HashSet<_>>();
                        let _ = decision_tx.send(if resumable {
                            if provider {
                                // Match the production Dart approval: same-session
                                // support, with an explicitly empty durable set.
                                PrepareUploadDecisionV2::AcceptDurable {
                                    file_ids: ids.clone(),
                                    resumable_file_ids: ids,
                                    durable_file_ids: Default::default(),
                                }
                            } else {
                                PrepareUploadDecisionV2::AcceptResumable {
                                    file_ids: ids.clone(),
                                    resumable_file_ids: ids,
                                }
                            }
                        } else {
                            PrepareUploadDecisionV2::Accept(ids)
                        });
                    }
                    ServerEventV2::FileUpload {
                        file_id, target_tx, ..
                    } => {
                        target_count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let (result_tx, result_rx) = oneshot::channel();
                        let (progress_tx, mut progress_rx) = mpsc::channel(16);
                        let target = if provider {
                            let id = uuid::Uuid::new_v4().to_string();
                            let cache = dest.join(format!(".legnasend-receive-{id}.ls"));
                            let staging = dest.join(format!(".legnasend-receive-{id}.part"));
                            let create = |path: &PathBuf| {
                                std::fs::OpenOptions::new()
                                    .read(true)
                                    .write(true)
                                    .create_new(true)
                                    .open(path)
                                    .unwrap()
                            };
                            let target = FileUploadTarget::CachedOpenedFiles {
                                cache: create(&cache),
                                staging: create(&staging),
                                transaction_id: id.clone(),
                                result_tx,
                                progress_tx: Some(progress_tx),
                            };
                            provider_records.insert(id, (file_id, cache, staging));
                            target
                        } else {
                            FileUploadTarget::CachedPath {
                                path: dest.join(file_id),
                                result_tx,
                                progress_tx: Some(progress_tx),
                            }
                        };
                        let _ = target_tx.send(target);
                        let results = results.clone();
                        let progress = progress.clone();
                        tokio::spawn(async move {
                            let _ = results.send(
                                result_rx
                                    .await
                                    .unwrap_or_else(|_| Err("request dropped".into())),
                            );
                        });
                        tokio::spawn(async move {
                            while let Some(n) = progress_rx.recv().await {
                                let _ = progress.send(n);
                            }
                        });
                    }
                    ServerEventV2::ReceiveCacheIdentity {
                        transaction_id,
                        identity_json,
                        result_tx,
                        ..
                    } => {
                        let (_, cache, staging) = provider_records.get(&transaction_id).unwrap();
                        // No cache header or body may precede durable approval.
                        assert_eq!(std::fs::metadata(cache).unwrap().len(), 0);
                        assert_eq!(std::fs::metadata(staging).unwrap().len(), 0);
                        let identity: localsend::download_cache::CacheIdentity =
                            serde_json::from_str(&identity_json).unwrap();
                        assert_eq!(identity.task_id, transaction_id);
                        assert_eq!(identity.resource_id, identity.sha256.clone().unwrap());
                        assert_eq!(identity.version, identity.sha256.clone().unwrap());
                        assert_eq!(identity.source_id.starts_with("cert:"), tls);
                        assert_eq!(identity.source_id.starts_with("http:"), !tls);
                        if reject_identity {
                            let _ = result_tx.send(Err("Journal not writable".into()));
                        } else {
                            use std::io::Write;
                            let mut journal = std::fs::OpenOptions::new()
                                .create_new(true)
                                .write(true)
                                .open(dest.join(format!("identity-{transaction_id}.json")))
                                .unwrap();
                            journal.write_all(identity_json.as_bytes()).unwrap();
                            journal.sync_all().unwrap();
                            drop(journal);
                            // The native journal selects a candidate; core must still
                            // validate every identity attribute and committed record.
                            let source = recovery_journal.as_ref().map(|journal| {
                                let identity: localsend::download_cache::CacheIdentity =
                                    serde_json::from_slice(&std::fs::read(journal).unwrap())
                                        .unwrap();
                                let transaction_id = identity.task_id.clone();
                                let file = std::fs::File::open(
                                    dest.join(format!(".legnasend-receive-{transaction_id}.ls")),
                                )
                                .unwrap();
                                localsend::http::server::v2::CacheRecoverySource {
                                    file,
                                    identity,
                                    transaction_id,
                                }
                            });
                            let _ = result_tx.send(Ok(source));
                        }
                    }
                    ServerEventV2::ReceiveCacheRecovered {
                        transaction_id,
                        source_transaction_id,
                        source_length,
                        source_sha256,
                        result_tx,
                        ..
                    } => {
                        let source =
                            dest.join(format!(".legnasend-receive-{source_transaction_id}.ls"));
                        // Recovery closes the old read-only description before
                        // asking native to persist the migration receipt.
                        std::fs::OpenOptions::new()
                            .read(true)
                            .write(true)
                            .open(&source)
                            .unwrap()
                            .try_lock()
                            .unwrap();
                        let original_container = std::fs::read(&source).unwrap();
                        assert_eq!(source_length, original_container.len() as u64);
                        assert_eq!(source_sha256, sha(&original_container));
                        let (_, cache, _) = provider_records.get(&transaction_id).unwrap();
                        assert_eq!(read_cache_identity(cache).task_id, transaction_id);
                        if dest.join("delay-migration-receipt").exists() {
                            tokio::time::sleep(Duration::from_millis(600)).await;
                        }
                        if dest.join("reject-migration-receipt").exists() {
                            let _ = result_tx.send(Err("Migration receipt not writable".into()));
                            continue;
                        }
                        let _ = recovered.send((
                            transaction_id,
                            source_transaction_id,
                            source_length,
                            source_sha256,
                        ));
                        let _ = result_tx.send(Ok(()));
                    }
                    ServerEventV2::PublishUpload {
                        transaction_id,
                        size,
                        sha256,
                        result_tx,
                        ..
                    } => {
                        let (name, cache, staging) = provider_records.get(&transaction_id).unwrap();
                        // Native publication is requested only after both core
                        // descriptions close, not just after progress reaches size.
                        let open = |path: &PathBuf| {
                            std::fs::OpenOptions::new()
                                .read(true)
                                .write(true)
                                .open(path)
                                .unwrap()
                        };
                        open(cache).try_lock().unwrap();
                        open(staging).try_lock().unwrap();
                        let bytes = std::fs::read(staging).unwrap();
                        assert_eq!(bytes.len() as u64, size);
                        assert_eq!(sha(&bytes), sha256);
                        let published = (|| -> std::io::Result<()> {
                            use std::io::Write;
                            let mut output = std::fs::OpenOptions::new()
                                .write(true)
                                .create_new(true)
                                .open(dest.join(name))?;
                            output.write_all(&bytes)?;
                            output.sync_all()?;
                            drop(output);
                            assert_eq!(std::fs::read(dest.join(name))?, bytes);
                            Ok(())
                        })();
                        // Match native recovery: historical documents remain
                        // read-only and retained. Publication only authorizes
                        // cleanup of this newly owned transaction's temporaries.
                        let _ = result_tx.send(published.map_err(|error| error.to_string()));
                    }
                    ServerEventV2::UploadCacheReleased { transaction_id, .. } => {
                        let (_, cache, staging) = provider_records.remove(&transaction_id).unwrap();
                        for path in [cache, staging] {
                            let opened = std::fs::OpenOptions::new()
                                .read(true)
                                .write(true)
                                .open(&path)
                                .unwrap();
                            opened.try_lock().unwrap();
                            drop(opened);
                            std::fs::remove_file(path).unwrap();
                        }
                    }
                    _ => {}
                }
            }
        });
        let (tx, rx) = oneshot::channel();
        let server = start_with_port(
            0,
            certificate.map(|cert| localsend::http::server::TlsConfig {
                cert: cert.certificate_pem,
                private_key: cert.private_key_pem,
            }),
            ClientInfo {
                alias: "cache receiver".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: "receiver".into(),
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx: events,
            }),
            WebConfig::default(),
            rx,
        )
        .await
        .unwrap();
        Self {
            _slot: slot,
            dir,
            targets,
            url: format!(
                "{}://127.0.0.1:{}",
                if tls { "https" } else { "http" },
                server.port()
            ),
            server,
            stop: Some(tx),
            client,
            results: results_rx,
            progress: progress_rx,
            recovered: recovered_rx,
        }
    }
    async fn prepare(&self, size: u64, hash: Option<String>) -> Value {
        let request = json!({"info":{"alias":"original-v2-sender","version":"2.2","fingerprint":"sender","port":53317,"protocol":"http"},
            "files":{"out":{"id":"out","fileName":"out","size":size,"fileType":"application/octet-stream","sha256":hash}}});
        let response = self
            .client
            .post(format!("{}/api/localsend/v2/prepare-upload", self.url))
            .json(&request)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    fn upload(&self, session: &Value) -> reqwest::RequestBuilder {
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("sessionId", session["sessionId"].as_str().unwrap())
            .append_pair("fileId", "out")
            .append_pair("token", session["files"]["out"].as_str().unwrap())
            .finish();
        self.client
            .post(format!("{}/api/localsend/v2/upload?{query}", self.url))
    }
    async fn clean(&self) {
        for _ in 0..200 {
            if std::fs::read_dir(&self.dir).unwrap().all(|e| {
                !e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".legnasend-receive-")
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("Owned receive files were not cleaned");
    }
    async fn released_except(&self, retained_transaction: &str) {
        let retained = format!(".legnasend-receive-{retained_transaction}.");
        for _ in 0..200 {
            if std::fs::read_dir(&self.dir).unwrap().all(|entry| {
                let name = entry.unwrap().file_name();
                let name = name.to_string_lossy();
                !name.starts_with(".legnasend-receive-") || name.starts_with(&retained)
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("Failed new transaction did not release its owned files");
    }
    async fn result(&mut self) -> Result<(), String> {
        tokio::time::timeout(Duration::from_secs(5), self.results.recv())
            .await
            .unwrap()
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.take();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

const BLOCK: usize = 1024 * 1024;
fn sha(bytes: &[u8]) -> String {
    localsend::crypto::hash::sha256_hex(bytes).to_ascii_lowercase()
}
impl Fixture {
    fn extension(&self, action: &str, session: &Value, resume: Option<&Value>) -> String {
        let mut query = form_urlencoded::Serializer::new(String::new());
        query
            .append_pair("sessionId", session["sessionId"].as_str().unwrap())
            .append_pair("fileId", "out")
            .append_pair("token", session["files"]["out"].as_str().unwrap());
        if let Some(resume) = resume {
            query.append_pair("resumeId", resume["resumeId"].as_str().unwrap());
        }
        format!(
            "{}/api/legnasend/v1/receive-resume/{}?{}",
            self.url,
            action,
            query.finish()
        )
    }
    async fn open(&self, session: &Value, bytes: &[u8]) -> Value {
        let response = self
            .client
            .post(self.extension("open", session, None))
            .json(&json!({"size":bytes.len(),"sha256":sha(bytes)}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    async fn block(
        &self,
        session: &Value,
        resume: &Value,
        offset: usize,
        bytes: &[u8],
    ) -> reqwest::Response {
        self.client
            .put(format!(
                "{}&offset={offset}",
                self.extension("block", session, Some(resume))
            ))
            .header("X-LegnaSend-Block-Sha256", sha(bytes))
            .body(bytes.to_vec())
            .send()
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn interrupted_block_resumes_same_logical_file_and_complete_ack_survives_next_session() {
    use tokio::io::AsyncWriteExt;
    let mut f = Fixture::new(true).await;
    let bytes = (0..BLOCK * 2 + 313)
        .map(|i| (i % 251) as u8)
        .collect::<Vec<_>>();
    let session = f.prepare(bytes.len() as u64, None).await;
    let cap = f
        .client
        .get(f.extension("capabilities", &session, None))
        .send()
        .await
        .unwrap();
    assert_eq!(cap.status(), 200);
    let resume = f.open(&session, &bytes).await;
    assert_eq!(
        f.block(&session, &resume, 0, &bytes[..BLOCK])
            .await
            .status(),
        200
    );
    let url = format!(
        "{}&offset={BLOCK}",
        f.extension("block", &session, Some(&resume))
    );
    let url = reqwest::Url::parse(&url).unwrap();
    let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", f.server.port()))
        .await
        .unwrap();
    let headers = format!(
        "PUT {}?{} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nX-LegnaSend-Block-Sha256: {}\r\n\r\n",
        url.path(),
        url.query().unwrap(),
        BLOCK,
        sha(&bytes[BLOCK..2 * BLOCK])
    );
    socket.write_all(headers.as_bytes()).await.unwrap();
    socket.write_all(&bytes[BLOCK..BLOCK + 4096]).await.unwrap();
    socket.shutdown().await.unwrap();
    drop(socket);
    tokio::time::sleep(Duration::from_millis(80)).await;
    let status: Value = f
        .client
        .get(f.extension("status", &session, Some(&resume)))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(status["offset"], BLOCK);
    assert!(f.results.try_recv().is_err());
    let same = f.open(&session, &bytes).await;
    assert_eq!(same["resumeId"], resume["resumeId"]);
    assert_eq!(f.targets.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(
        f.client
            .get(format!(
                "{}&token=wrong",
                f.extension("status", &session, Some(&resume))
            ))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    let wrong = f
        .extension("status", &session, Some(&resume))
        .replace(session["files"]["out"].as_str().unwrap(), "wrong");
    assert_eq!(f.client.get(wrong).send().await.unwrap().status(), 403);
    for start in [BLOCK, 2 * BLOCK] {
        assert_eq!(
            f.block(
                &session,
                &resume,
                start,
                &bytes[start..(start + BLOCK).min(bytes.len())]
            )
            .await
            .status(),
            200
        );
    }
    let finish = f
        .client
        .post(f.extension("finish", &session, Some(&resume)))
        .send()
        .await
        .unwrap();
    assert_eq!(finish.status(), 200);
    assert_eq!(finish.json::<Value>().await.unwrap()["state"], "complete");
    assert!(f.result().await.is_ok());
    f.clean().await;
    assert_eq!(sha(&std::fs::read(f.dir.join("out")).unwrap()), sha(&bytes));
    tokio::time::sleep(Duration::from_millis(30)).await;
    let next = f.prepare(1, None).await;
    assert_eq!(
        f.client
            .get(f.extension("status", &session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap()["state"],
        "complete"
    );
    f.client
        .post(format!(
            "{}/api/localsend/v2/cancel?sessionId={}",
            f.url,
            session["sessionId"].as_str().unwrap()
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(
        f.client
            .get(f.extension("status", &session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .status(),
        410
    );
    assert!(
        f.server
            .cancel_v2_session(next["sessionId"].as_str().unwrap())
            .await
    );
}

#[tokio::test]
async fn unsupported_receiver_keeps_original_wire_and_never_dispatches_probe_target() {
    let mut f = Fixture::new(false).await;
    let bytes = vec![7; BLOCK];
    let session = f.prepare(bytes.len() as u64, None).await;
    assert_eq!(
        f.client
            .get(f.extension("capabilities", &session, None))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    assert_eq!(f.targets.load(std::sync::atomic::Ordering::SeqCst), 0);
    assert_eq!(
        f.upload(&session)
            .body(bytes.clone())
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert!(f.result().await.is_ok());
    f.clean().await;
    assert_eq!(std::fs::read(f.dir.join("out")).unwrap(), bytes);
}

#[tokio::test]
async fn explicit_abort_and_invalid_hash_remove_only_owned_partial_files() {
    for invalid_hash in [false, true] {
        let mut f = Fixture::new(true).await;
        let bytes = vec![9; 2 * BLOCK];
        let session = f.prepare(bytes.len() as u64, None).await;
        let resume = f.open(&session, &bytes).await;
        assert_eq!(
            f.block(&session, &resume, 0, &bytes[..BLOCK])
                .await
                .status(),
            200
        );
        std::fs::write(f.dir.join("unrelated.ls"), b"keep").unwrap();
        if invalid_hash {
            assert_eq!(
                f.client
                    .put(format!(
                        "{}&offset={BLOCK}",
                        f.extension("block", &session, Some(&resume))
                    ))
                    .header("X-LegnaSend-Block-Sha256", "0".repeat(64))
                    .body(bytes[BLOCK..].to_vec())
                    .send()
                    .await
                    .unwrap()
                    .status(),
                422
            );
        } else {
            let response = f
                .client
                .post(f.extension("abort", &session, Some(&resume)))
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            let response: serde_json::Value = response.json().await.unwrap();
            assert_eq!(response["state"], "cancelling");
        }
        assert!(f.result().await.is_err());
        f.clean().await;
        assert!(!f.dir.join("out").exists());
        assert_eq!(std::fs::read(f.dir.join("unrelated.ls")).unwrap(), b"keep");
        tokio::time::sleep(Duration::from_millis(30)).await;
        let next = f.prepare(1, None).await;
        assert_eq!(
            f.upload(&next).body("x").send().await.unwrap().status(),
            200
        );
        assert!(f.result().await.is_ok());
    }
}

#[tokio::test]
async fn finish_requires_whole_hash_and_nonoverwriting_publication() {
    for collision in [false, true] {
        let mut f = Fixture::new(true).await;
        let bytes = vec![5; BLOCK];
        let session = f.prepare(bytes.len() as u64, None).await;
        let resume = f
            .open(
                &session,
                &if collision {
                    bytes.clone()
                } else {
                    vec![6; BLOCK]
                },
            )
            .await;
        assert_eq!(f.block(&session, &resume, 0, &bytes).await.status(), 200);
        if collision {
            std::fs::write(f.dir.join("out"), b"existing").unwrap();
        }
        assert_eq!(
            f.client
                .post(f.extension("finish", &session, Some(&resume)))
                .send()
                .await
                .unwrap()
                .status(),
            500
        );
        assert!(f.result().await.is_err());
        f.clean().await;
        if collision {
            assert_eq!(std::fs::read(f.dir.join("out")).unwrap(), b"existing");
        } else {
            assert!(!f.dir.join("out").exists());
        }
    }
}

#[tokio::test]
async fn production_sender_path_negotiates_real_receiver_and_publishes_original_bytes() {
    use localsend::{
        crypto::cert::generate_self_signed,
        http::client::{LsHttpClient, LsHttpClientVersion},
        model::{discovery::ProtocolType, transfer::FileContent},
    };
    let mut f = Fixture::new(true).await;
    let bytes = (0..2 * BLOCK + 123)
        .map(|i| (i % 241) as u8)
        .collect::<Vec<_>>();
    let source = f.dir.join("source");
    std::fs::write(&source, &bytes).unwrap();
    let session = f.prepare(bytes.len() as u64, None).await;
    let cert = generate_self_signed().unwrap();
    let client = LsHttpClient::new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(10)),
    )
    .unwrap();
    client
        .upload(
            ProtocolType::Http,
            "127.0.0.1",
            f.server.port(),
            None,
            session["sessionId"].as_str().unwrap(),
            "out",
            session["files"]["out"].as_str().unwrap(),
            FileContent::Path(source),
            |_| {},
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(f.result().await.is_ok());
    f.clean().await;
    assert_eq!(f.targets.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(sha(&std::fs::read(f.dir.join("out")).unwrap()), sha(&bytes));
    let mut progress = Vec::new();
    while let Ok(n) = f.progress.try_recv() {
        progress.push(n);
    }
    assert_eq!(progress.last(), Some(&(bytes.len() as u64)));
}

fn new_identity() -> reqwest::Identity {
    let c = localsend::crypto::cert::generate_self_signed().unwrap();
    reqwest::Identity::from_pem(format!("{}\n{}", c.private_key_pem, c.certificate_pem).as_bytes())
        .unwrap()
}
#[tokio::test]
async fn tls_same_ip_wrong_certificate_cannot_query_or_abort_another_receipt() {
    let mut f = Fixture::with_tls(true, true).await;
    let bytes = vec![4; BLOCK];
    let session = f.prepare(bytes.len() as u64, None).await;
    let resume = f.open(&session, &bytes).await;
    let other = reqwest::Client::builder()
        .no_proxy()
        .danger_accept_invalid_certs(true)
        .identity(new_identity())
        .build()
        .unwrap();
    for action in ["capabilities", "status", "abort"] {
        let url = f.extension(
            action,
            &session,
            if action == "capabilities" {
                None
            } else {
                Some(&resume)
            },
        );
        let request = if action == "abort" {
            other.post(url)
        } else {
            other.get(url)
        };
        assert_eq!(request.send().await.unwrap().status(), 403);
    }
    let rejected_cancel = other
        .post(format!(
            "{}/api/localsend/v2/cancel?sessionId={}",
            f.url,
            session["sessionId"].as_str().unwrap()
        ))
        .send()
        .await
        .unwrap();
    // Legacy cancel responses stay 200, but this different certificate must not
    // revoke the negotiated transaction or its accepted session.
    assert_eq!(rejected_cancel.status(), 200);
    assert_eq!(
        f.client
            .get(f.extension("status", &session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(f.block(&session, &resume, 0, &bytes).await.status(), 200);
    assert_eq!(
        f.client
            .post(f.extension("finish", &session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert!(f.result().await.is_ok());
    f.clean().await;
    assert_eq!(
        other
            .get(f.extension("status", &session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
}

#[tokio::test]
async fn listener_stop_releases_partial_writer_without_publishing_or_harming_other_files() {
    let mut f = Fixture::new(true).await;
    let bytes = vec![17; BLOCK * 2];
    let session = f.prepare(bytes.len() as u64, None).await;
    let resume = f.open(&session, &bytes).await;
    assert_eq!(
        f.block(&session, &resume, 0, &bytes[..BLOCK])
            .await
            .status(),
        200
    );
    std::fs::write(f.dir.join("user-owned.ls"), b"keep").unwrap();
    f.stop.take();
    assert!(f.result().await.is_err());
    f.clean().await;
    assert!(!f.dir.join("out").exists());
    assert_eq!(std::fs::read(f.dir.join("user-owned.ls")).unwrap(), b"keep");
}

#[tokio::test]
async fn rejected_provider_identity_never_writes_a_cache_header_or_publishes() {
    let mut f = Fixture::with_options(true, false, true, true).await;
    let bytes = vec![13; BLOCK];
    let session = f.prepare(bytes.len() as u64, None).await;
    let response = f
        .client
        .post(f.extension("open", &session, None))
        .json(&json!({"size":bytes.len(),"sha256":sha(&bytes)}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(f.result().await.is_err());
    f.clean().await;
    assert!(!f.dir.join("out").exists());
    assert_eq!(std::fs::read_dir(&f.dir).unwrap().count(), 0);
}

#[tokio::test]
async fn provider_identity_is_stable_across_new_approvals_without_reusing_attempt_or_token() {
    let mut f = Fixture::with_options(true, false, true, false).await;
    let bytes = vec![14; BLOCK];
    let mut identities = Vec::new();
    let mut sessions = Vec::new();
    for _ in 0..2 {
        let session = f.prepare(bytes.len() as u64, None).await;
        let resume = f.open(&session, &bytes).await;
        let response = f
            .client
            .post(f.extension("abort", &session, Some(&resume)))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(f.result().await.is_err());
        f.clean().await;
        for entry in std::fs::read_dir(&f.dir).unwrap() {
            let entry = entry.unwrap();
            if entry.file_name().to_string_lossy().starts_with("identity-") {
                identities.push(
                    serde_json::from_slice::<localsend::download_cache::CacheIdentity>(
                        &std::fs::read(entry.path()).unwrap(),
                    )
                    .unwrap(),
                );
                std::fs::remove_file(entry.path()).unwrap();
            }
        }
        sessions.push(session);
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    assert_eq!(identities.len(), 2);
    assert_eq!(identities[0].source_id, identities[1].source_id);
    assert_eq!(identities[0].resource_id, identities[1].resource_id);
    assert_eq!(identities[0].sha256, identities[1].sha256);
    assert_ne!(identities[0].task_id, identities[1].task_id);
    assert_ne!(sessions[0]["sessionId"], sessions[1]["sessionId"]);
    assert_ne!(sessions[0]["files"]["out"], sessions[1]["files"]["out"]);
}

fn read_cache_identity(path: &std::path::Path) -> localsend::download_cache::CacheIdentity {
    use std::io::Read;
    let mut file = std::fs::File::open(path).unwrap();
    let mut header = [0; 16];
    file.read_exact(&mut header).unwrap();
    let length = u32::from_le_bytes(header[12..16].try_into().unwrap()) as usize;
    assert!(length <= 16 * 1024);
    let mut json = vec![0; length];
    file.read_exact(&mut json).unwrap();
    serde_json::from_slice(&json).unwrap()
}

fn restart_bytes() -> Vec<u8> {
    (0..BLOCK * 2 + 137).map(|i| (i % 239) as u8).collect()
}

/// A real server process receives and durably acknowledges one block, then
/// exits without dropping the fixture or releasing its native-owned documents.
#[tokio::test]
async fn provider_restart_seed_process() {
    let Some(directory) = std::env::var_os("LEGNA_RECEIVE_RESTART_SEED") else {
        return;
    };
    let directory = PathBuf::from(directory);
    let f = Fixture::with_storage(true, false, true, false, Some(directory.clone()), None).await;
    let bytes = restart_bytes();
    let session = f.prepare(bytes.len() as u64, Some(sha(&bytes))).await;
    let resume = f.open(&session, &bytes).await;
    assert_eq!(
        f.block(&session, &resume, 0, &bytes[..BLOCK])
            .await
            .status(),
        200
    );
    std::fs::write(
        directory.join("old-session.json"),
        serde_json::to_vec(&session).unwrap(),
    )
    .unwrap();
    // Exit skips Rust destructors, server-stop callbacks and fixture cleanup.
    // The OS closes every descriptor and releases the writer's strict locks.
    std::process::exit(0);
}

async fn crashed_provider_directory() -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "legnasend-provider-restart-{}",
        uuid::Uuid::new_v4()
    ));
    let child_directory = directory.clone();
    let output = tokio::task::spawn_blocking(move || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "provider_restart_seed_process", "--nocapture"])
            .env("LEGNA_RECEIVE_RESTART_SEED", child_directory)
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(
        output.status.success(),
        "seed process failed: {}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(directory.join("old-session.json").exists());
    directory
}

fn recovery_journal(directory: &std::path::Path) -> PathBuf {
    let journals: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap())
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("identity-"))
        .map(|entry| entry.path())
        .collect();
    assert_eq!(journals.len(), 1);
    journals[0].clone()
}

#[tokio::test]
async fn crashed_provider_new_approval_reuses_synced_block_and_publishes_remaining_bytes() {
    let directory = crashed_provider_directory().await;
    let journal = recovery_journal(&directory);
    let previous: localsend::download_cache::CacheIdentity =
        serde_json::from_slice(&std::fs::read(&journal).unwrap()).unwrap();
    let old_cache = directory.join(format!(".legnasend-receive-{}.ls", previous.task_id));
    let old_cache_bytes = std::fs::read(&old_cache).unwrap();
    let old_staging = directory.join(format!(".legnasend-receive-{}.part", previous.task_id));
    let old_staging_bytes = std::fs::read(&old_staging).unwrap();
    let previous_session: Value =
        serde_json::from_slice(&std::fs::read(directory.join("old-session.json")).unwrap())
            .unwrap();
    let mut f =
        Fixture::with_storage(true, false, true, false, Some(directory), Some(journal)).await;
    let bytes = restart_bytes();
    let session = f.prepare(bytes.len() as u64, Some(sha(&bytes))).await;
    assert_ne!(session["sessionId"], previous_session["sessionId"]);
    assert_ne!(session["files"]["out"], previous_session["files"]["out"]);
    let capabilities: Value = f
        .client
        .get(f.extension("capabilities", &session, None))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(capabilities.get("durable").is_none());
    let resume = f.open(&session, &bytes).await;
    assert!(resume.get("sourceEnd").is_none());
    assert_eq!(resume["offset"], BLOCK);
    let (new_id, source_id, source_length, source_sha256) =
        tokio::time::timeout(Duration::from_secs(5), f.recovered.recv())
            .await
            .unwrap()
            .unwrap();
    assert_eq!(source_id, previous.task_id);
    assert_ne!(new_id, source_id);
    assert_eq!(source_length, old_cache_bytes.len() as u64);
    assert_eq!(source_sha256, sha(&old_cache_bytes));
    assert_eq!(
        read_cache_identity(&f.dir.join(format!(".legnasend-receive-{new_id}.ls"))).task_id,
        new_id
    );
    assert_eq!(std::fs::read(&old_cache).unwrap(), old_cache_bytes);
    // Old session credentials cannot drive the freshly approved transaction.
    assert_eq!(
        f.client
            .get(f.extension("status", &previous_session, Some(&resume)))
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let mut network_bytes = 0;
    for offset in (BLOCK..bytes.len()).step_by(BLOCK) {
        let block = &bytes[offset..(offset + BLOCK).min(bytes.len())];
        assert_eq!(
            f.block(&session, &resume, offset, block).await.status(),
            200
        );
        network_bytes += block.len();
    }
    assert_eq!(network_bytes, bytes.len() - BLOCK);
    let response = f
        .client
        .post(f.extension("finish", &session, Some(&resume)))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.json::<Value>().await.unwrap()["state"], "complete");
    assert!(f.result().await.is_ok());
    f.released_except(&previous.task_id).await;
    assert_eq!(std::fs::read(&old_cache).unwrap(), old_cache_bytes);
    assert_eq!(std::fs::read(&old_staging).unwrap(), old_staging_bytes);
    assert_eq!(sha(&std::fs::read(f.dir.join("out")).unwrap()), sha(&bytes));
    assert_eq!(f.targets.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn crashed_provider_mismatched_candidate_does_not_report_restored_offset_or_publish() {
    let directory = crashed_provider_directory().await;
    let journal = recovery_journal(&directory);
    let mut previous: localsend::download_cache::CacheIdentity =
        serde_json::from_slice(&std::fs::read(&journal).unwrap()).unwrap();
    let old_cache = directory.join(format!(".legnasend-receive-{}.ls", previous.task_id));
    let old_bytes = std::fs::read(&old_cache).unwrap();
    previous.source_id = "http:192.0.2.44".into();
    std::fs::write(&journal, serde_json::to_vec(&previous).unwrap()).unwrap();
    let mut f =
        Fixture::with_storage(true, false, true, false, Some(directory), Some(journal)).await;
    let bytes = restart_bytes();
    let session = f.prepare(bytes.len() as u64, Some(sha(&bytes))).await;
    let response = f
        .client
        .post(f.extension("open", &session, None))
        .json(&json!({"size":bytes.len(),"sha256":sha(&bytes)}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    assert!(f.result().await.is_err());
    assert!(f.recovered.try_recv().is_err());
    assert!(!f.dir.join("out").exists());
    assert_eq!(std::fs::read(old_cache).unwrap(), old_bytes);
    f.released_except(&previous.task_id).await;
}

#[tokio::test]
async fn provider_recovery_requires_old_writer_release_and_durable_migration_ack() {
    for block_with_writer in [true, false] {
        let directory = crashed_provider_directory().await;
        let journal = recovery_journal(&directory);
        let previous: localsend::download_cache::CacheIdentity =
            serde_json::from_slice(&std::fs::read(&journal).unwrap()).unwrap();
        let old_cache = directory.join(format!(".legnasend-receive-{}.ls", previous.task_id));
        let old_bytes = std::fs::read(&old_cache).unwrap();
        let writer = if block_with_writer {
            let writer = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&old_cache)
                .unwrap();
            writer.try_lock().unwrap();
            Some(writer)
        } else {
            std::fs::write(directory.join("reject-migration-receipt"), b"reject").unwrap();
            None
        };
        let mut f =
            Fixture::with_storage(true, false, true, false, Some(directory), Some(journal)).await;
        let bytes = restart_bytes();
        let session = f.prepare(bytes.len() as u64, Some(sha(&bytes))).await;
        let response = f
            .client
            .post(f.extension("open", &session, None))
            .json(&json!({"size":bytes.len(),"sha256":sha(&bytes)}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 500);
        assert!(f.result().await.is_err());
        assert!(f.recovered.try_recv().is_err());
        assert!(!f.dir.join("out").exists());
        assert_eq!(std::fs::read(&old_cache).unwrap(), old_bytes);
        drop(writer);
        f.released_except(&previous.task_id).await;
    }
}

#[tokio::test]
async fn production_sender_waits_for_provider_verification_without_durable_negotiation() {
    use localsend::{
        crypto::cert::generate_self_signed,
        http::client::{LsHttpClient, LsHttpClientVersion},
        model::{discovery::ProtocolType, transfer::FileContent},
    };
    let directory = crashed_provider_directory().await;
    let journal = recovery_journal(&directory);
    let previous: localsend::download_cache::CacheIdentity =
        serde_json::from_slice(&std::fs::read(&journal).unwrap()).unwrap();
    let old_cache = directory.join(format!(".legnasend-receive-{}.ls", previous.task_id));
    let old_cache_bytes = std::fs::read(&old_cache).unwrap();
    let old_staging = directory.join(format!(".legnasend-receive-{}.part", previous.task_id));
    let old_staging_bytes = std::fs::read(&old_staging).unwrap();
    std::fs::write(directory.join("delay-migration-receipt"), b"delay").unwrap();
    let mut f =
        Fixture::with_storage(true, false, true, false, Some(directory), Some(journal)).await;
    let bytes = restart_bytes();
    let source = f.dir.join("source");
    std::fs::write(&source, &bytes).unwrap();
    let session = f.prepare(bytes.len() as u64, Some(sha(&bytes))).await;
    let cert = generate_self_signed().unwrap();
    let client = LsHttpClient::new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(10)),
    )
    .unwrap();
    let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
    let (verification_tx, mut verification_rx) = mpsc::unbounded_channel();
    client
        .upload_with_recovery(
            ProtocolType::Http,
            "127.0.0.1",
            f.server.port(),
            None,
            session["sessionId"].as_str().unwrap(),
            "out",
            session["files"]["out"].as_str().unwrap(),
            FileContent::Path(source),
            None,
            move |bytes| {
                let _ = progress_tx.send(bytes);
            },
            move |bytes, total| {
                let _ = verification_tx.send((bytes, total));
            },
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(f.result().await.is_ok());
    assert!(f.recovered.try_recv().is_ok());
    // Delay exceeds the server's 200 ms open response window. The production
    // sender must observe and poll verification rather than aborting it as an
    // unnegotiated durable capability or sending the first block again.
    assert_eq!(
        verification_rx.try_recv().unwrap(),
        (BLOCK as u64, bytes.len() as u64)
    );
    assert_eq!(progress_rx.try_recv().unwrap(), BLOCK as u64);
    f.released_except(&previous.task_id).await;
    assert_eq!(std::fs::read(&old_cache).unwrap(), old_cache_bytes);
    assert_eq!(std::fs::read(&old_staging).unwrap(), old_staging_bytes);
    assert_eq!(sha(&std::fs::read(f.dir.join("out")).unwrap()), sha(&bytes));
    assert_eq!(f.targets.load(std::sync::atomic::Ordering::SeqCst), 1);
}
