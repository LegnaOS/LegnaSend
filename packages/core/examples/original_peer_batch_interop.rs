//! Explicit-root, loopback-only manual original-app interoperability fixture.
//! `generate ROOT [COUNT]` is offline; `run ROOT PEER_PORT [CONCURRENCY] [SECONDS]`
//! starts the real production HTTPS v2 server only when the operator invokes it.
use anyhow::{Context, ensure};
use futures_util::{StreamExt, stream};
use localsend::{
    crypto::{cert::generate_self_signed, hash::sha256_hex},
    http::{
        client::LsHttpClientV2,
        dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2},
        server::{
            ServerConfigV2, TlsConfig,
            common::save::FileUploadTarget,
            start_loopback_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            web::WebConfig,
        },
        state::ClientInfo,
    },
    model::{
        discovery::{DeviceType, ProtocolType},
        transfer::FileDto,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
const ALIAS: &str = "LegnaSend Original 5000 Fixture";
const MAX_FILES: usize = 10_000;
const MAX_FILE_BYTES: usize = 1151;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Entry {
    id: String,
    path: String,
    size: u64,
    sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Manifest {
    schema: u32,
    generator: String,
    count: usize,
    total_bytes: u64,
    top_directory: String,
    entries: Vec<Entry>,
}
fn payload(index: usize, path: &str) -> Vec<u8> {
    let size = 128 + (index * 37) % 1024;
    let marker = format!("LegnaSend original-v2 fixture v1\n{index}\n{path}\n");
    (0..size)
        .map(|offset| {
            if offset < marker.len() {
                marker.as_bytes()[offset]
            } else {
                ((index as u64 * 131 + offset as u64 * 17) % 251) as u8
            }
        })
        .collect()
}
fn manifest(count: usize) -> anyhow::Result<Manifest> {
    ensure!((1..=MAX_FILES).contains(&count), "COUNT must be 1..10000");
    let top = format!("LegnaSend-original-{count}");
    let mut entries = Vec::with_capacity(count);
    for index in 0..count {
        let depth = match index % 3 {
            0 => "資料",
            1 => "資料/日本語",
            _ => "資料/日本語/多层",
        };
        let path = format!("{top}/组-{:02}/{depth}/文件-{index:05}-😀.bin", index / 100);
        let bytes = payload(index, &path);
        entries.push(Entry {
            id: format!("fixture-{index:05}"),
            path,
            size: bytes.len() as u64,
            sha256: sha256_hex(&bytes),
        });
    }
    Ok(Manifest {
        schema: 1,
        generator: "legnasend-original-v2-v1".into(),
        count,
        total_bytes: entries.iter().map(|e| e.size).sum(),
        top_directory: top,
        entries,
    })
}
fn root(path: &str, create: bool) -> anyhow::Result<PathBuf> {
    let path = PathBuf::from(path);
    ensure!(path.is_absolute(), "ROOT must be explicit and absolute");
    if create {
        fs::create_dir_all(&path)?;
    }
    let metadata = fs::symlink_metadata(&path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "ROOT must be a real directory, not a link"
    );
    Ok(path.canonicalize()?)
}
fn safe_relative(relative: &str) -> anyhow::Result<()> {
    ensure!(
        !relative.is_empty() && !relative.contains(['\\', '\0', ':']),
        "Invalid relative fixture path"
    );
    ensure!(
        relative
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != ".."),
        "Noncanonical fixture path"
    );
    ensure!(
        Path::new(relative)
            .components()
            .all(|c| matches!(c, Component::Normal(_))),
        "Only normal path components are allowed"
    );
    Ok(())
}
fn directory(root: &Path, relative: &str) -> anyhow::Result<PathBuf> {
    safe_relative(relative)?;
    let mut result = root.to_path_buf();
    for component in Path::new(relative).components() {
        result.push(component);
        match fs::symlink_metadata(&result) {
            Ok(m) => ensure!(
                m.is_dir() && !m.file_type().is_symlink(),
                "Fixture directory replaced"
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&result)?;
                ensure!(fs::symlink_metadata(&result)?.is_dir(), "Not a directory");
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(result)
}
fn read_file(root: &Path, relative: &str, limit: usize) -> anyhow::Result<Vec<u8>> {
    use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
    safe_relative(relative)?;
    let mut dir = cap_std::fs::Dir::open_ambient_dir(root, cap_std::ambient_authority())?;
    let parts = relative.split('/').collect::<Vec<_>>();
    for part in &parts[..parts.len() - 1] {
        dir = dir.open_dir_nofollow(part)?;
    }
    let mut options = cap_std::fs::OpenOptions::new();
    options.read(true).follow(FollowSymlinks::No);
    let file = dir.open_with(parts.last().unwrap(), &options)?;
    ensure!(file.metadata()?.is_file(), "Fixture source must be regular");
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit, "Fixture file too large");
    Ok(bytes)
}
fn create_file(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    Ok(())
}
fn generate(root: &Path, count: usize) -> anyhow::Result<Manifest> {
    let expected = manifest(count)?;
    let manifest_path = root.join("manifest.json");
    if manifest_path.exists() {
        ensure!(load(root)? == expected, "Existing fixture manifest differs");
    } else {
        ensure!(
            fs::read_dir(root)?.next().is_none(),
            "New fixture ROOT must be empty"
        );
        create_file(&manifest_path, &serde_json::to_vec_pretty(&expected)?)?;
    }
    for location in ["source", "received", "peer-downloads"] {
        directory(root, location)?;
    }
    for (index, entry) in expected.entries.iter().enumerate() {
        let relative = format!("source/{}", entry.path);
        let path = root.join(&relative);
        directory(
            root,
            Path::new(&relative).parent().unwrap().to_str().unwrap(),
        )?;
        if path.exists() {
            ensure!(
                read_file(root, &relative, MAX_FILE_BYTES)? == payload(index, &entry.path),
                "Existing generated source differs"
            );
        } else {
            create_file(&path, &payload(index, &entry.path))?;
        }
    }
    Ok(expected)
}
fn load(root: &Path) -> anyhow::Result<Manifest> {
    let value: Manifest =
        serde_json::from_slice(&read_file(root, "manifest.json", 4 * 1024 * 1024)?)?;
    ensure!(
        value == manifest(value.count)?,
        "Manifest is not the deterministic fixture allowlist"
    );
    Ok(value)
}
fn verify(root: &Path, location: &str, manifest: &Manifest) -> anyhow::Result<Vec<Entry>> {
    ensure!(
        ["source", "received", "peer-downloads"].contains(&location),
        "Unknown fixture location"
    );
    for entry in &manifest.entries {
        let bytes = read_file(root, &format!("{location}/{}", entry.path), MAX_FILE_BYTES)
            .with_context(|| {
                format!("Missing/invalid generated file: {location}/{}", entry.path)
            })?;
        ensure!(
            bytes.len() as u64 == entry.size && sha256_hex(&bytes) == entry.sha256,
            "Manifest hash mismatch: {}",
            entry.path
        );
    }
    Ok(manifest.entries.clone())
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Stats {
    info_calls: u64,
    register_calls: u64,
    prepare_calls: u64,
    prepare_failures: u64,
    upload_calls: u64,
    upload_failures: u64,
    sent_files: u64,
    sent_bytes: u64,
    incoming_prepare_calls: u64,
    incoming_rejected_prepares: u64,
    incoming_upload_events: u64,
    incoming_failures: u64,
    received_files: u64,
    received_bytes: u64,
    peak_outgoing: usize,
    peak_incoming: usize,
    peak_pending_targets: usize,
    approval_wait_ms: Option<u128>,
    forward_started_unix_ms: Option<u128>,
    forward_finished_unix_ms: Option<u128>,
    reverse_first_upload_event_unix_ms: Option<u128>,
    reverse_finished_unix_ms: Option<u128>,
    outgoing_body_ms: Option<u128>,
    first_upload_event_to_verified_save_ms: Option<u128>,
    forward_disk_verified: bool,
    reverse_disk_verified: bool,
    forward_verified: Vec<Entry>,
    reverse_verified: Vec<Entry>,
    errors: Vec<String>,
}
fn error(stats: &Mutex<Stats>, error: impl ToString) {
    let mut s = stats.lock().unwrap();
    if s.errors.len() < 50 {
        s.errors.push(error.to_string());
    }
}
fn wall_time() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
fn log(mut value: Value) {
    value
        .as_object_mut()
        .unwrap()
        .insert("wallTimeUnixMs".into(), json!(wall_time()));
    println!("{value}");
}
async fn receive(
    mut events: mpsc::Receiver<ServerEventV2>,
    root: PathBuf,
    manifest: Manifest,
    fingerprint: String,
    stats: Arc<Mutex<Stats>>,
    done: oneshot::Sender<anyhow::Result<()>>,
) {
    let expected: HashMap<_, _> = manifest
        .entries
        .iter()
        .map(|e| (e.path.clone(), e.clone()))
        .collect();
    let expected_basenames: HashSet<&str> = expected
        .keys()
        .filter_map(|p| p.rsplit('/').next())
        .collect();
    let mut pending = VecDeque::<(String, Entry, oneshot::Sender<FileUploadTarget>)>::new();
    let (complete, mut completed) = mpsc::channel::<(String, anyhow::Result<Entry>)>(16);
    let mut accepted = HashMap::<String, Entry>::new();
    let mut active_session = String::new();
    let mut started = None;
    let mut active = 0usize;
    let mut good = HashSet::new();
    let mut failed = false;
    let mut done = Some(done);
    enum Item {
        Event(Option<ServerEventV2>),
        Complete(Option<(String, anyhow::Result<Entry>)>),
    }
    loop {
        let item = tokio::select! {
            biased;
            result = completed.recv() => Item::Complete(result),
            event = events.recv(), if pending.len() < 32 => Item::Event(event),
        };
        match item {
            Item::Event(Some(ServerEventV2::PrepareUpload {
                session_id,
                info,
                ip,
                files,
                decision_tx,
                cert_fingerprint,
                ..
            })) => {
                stats.lock().unwrap().incoming_prepare_calls += 1;
                let mut names = HashSet::new();
                let valid = active_session.is_empty()
                    && ip.ip.is_loopback()
                    && cert_fingerprint.as_deref() == Some(&fingerprint)
                    && files.len() == expected.len()
                    && files.values().all(|file| {
                        expected.get(&file.file_name).is_some_and(|entry| {
                            entry.size == file.size
                                && file
                                    .sha256
                                    .as_ref()
                                    .is_none_or(|sha| sha.eq_ignore_ascii_case(&entry.sha256))
                                && names.insert(file.file_name.clone())
                        })
                    });
                if !valid {
                    stats.lock().unwrap().incoming_rejected_prepares += 1;
                    let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
                    log(
                        json!({"reverseRejected":true,"reason":"Manifest or pinned peer mismatch", "checks": {
                            "idle":active_session.is_empty(), "loopback":ip.ip.is_loopback(),
                            "certificateMatches":cert_fingerprint.as_deref()==Some(&fingerprint),
                            "expectedCount":expected.len(), "actualCount":files.len(),
                            "knownPaths":files.values().filter(|f|expected.contains_key(&f.file_name)).count(),
                            "knownNames":files.values().filter(|f|f.file_name.rsplit('/').next().is_some_and(|name| expected_basenames.contains(name))).count(),
                            "leadingSlash":files.values().filter(|f|f.file_name.starts_with('/')).count(),
                            "sizeMismatch":files.values().filter(|f|expected.get(&f.file_name).is_some_and(|e|e.size!=f.size)).count(),
                            "hashMismatch":files.values().filter(|f|expected.get(&f.file_name).is_some_and(|e|f.sha256.as_ref().is_some_and(|h|!h.eq_ignore_ascii_case(&e.sha256)))).count(),
                            "uniqueNames":files.values().map(|f|&f.file_name).collect::<HashSet<_>>().len()
                        }}),
                    );
                    continue;
                }
                accepted = files
                    .into_iter()
                    .map(|(id, file)| (id, expected[&file.file_name].clone()))
                    .collect();
                active_session = session_id;
                log(
                    json!({"reverseAccepted":manifest.count,"originalAlias":info.alias,"originalVersion":info.version,"certificatePinned":true}),
                );
                let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                    accepted.keys().cloned().collect(),
                ));
            }
            Item::Event(Some(ServerEventV2::FileUpload {
                session_id,
                file_id,
                file,
                target_tx,
            })) => {
                stats.lock().unwrap().incoming_upload_events += 1;
                let entry = accepted.remove(&file_id);
                if session_id != active_session
                    || entry
                        .as_ref()
                        .is_none_or(|entry| entry.path != file.file_name || entry.size != file.size)
                {
                    drop(target_tx);
                    stats.lock().unwrap().incoming_failures += 1;
                    failed = true;
                    error(&stats, "Unaccepted, duplicate or changed reverse file");
                } else {
                    if started.is_none() {
                        started = Some(Instant::now());
                        stats.lock().unwrap().reverse_first_upload_event_unix_ms =
                            Some(wall_time());
                        log(json!({"phase":"reverse-first-upload-event"}));
                    }
                    pending.push_back((file_id, entry.unwrap(), target_tx));
                    let mut s = stats.lock().unwrap();
                    s.peak_pending_targets = s.peak_pending_targets.max(pending.len());
                }
            }
            Item::Complete(Some((id, result))) => {
                active = active.saturating_sub(1);
                match result {
                    Ok(entry) => {
                        good.insert(id);
                        let mut s = stats.lock().unwrap();
                        s.received_files += 1;
                        s.received_bytes += entry.size;
                        s.reverse_verified.push(entry);
                        if s.received_files % 100 == 0 || s.received_files == manifest.count as u64
                        {
                            log(
                                json!({"reverseSavedAndHashed":s.received_files,"total":manifest.count}),
                            );
                        }
                    }
                    Err(e) => {
                        failed = true;
                        stats.lock().unwrap().incoming_failures += 1;
                        error(&stats, e);
                    }
                }
            }
            Item::Event(None) | Item::Complete(None) => break,
            Item::Event(Some(_)) => {}
        }
        // Verification uses the same bounded work slot as saving. When slots
        // fill, retain only 32 target responders and backpressure event reading;
        // completion messages always remain selectable, so there is no semaphore
        // wait inside the event handler and no full-completion-channel deadlock.
        while active < 8 {
            let Some((file_id, entry, target_tx)) = pending.pop_front() else {
                break;
            };
            let (result_tx, result_rx) = oneshot::channel();
            if target_tx
                .send(FileUploadTarget::CachedPath {
                    path: root.join("received").join(&entry.path),
                    result_tx,
                    progress_tx: None,
                })
                .is_err()
            {
                failed = true;
                stats.lock().unwrap().incoming_failures += 1;
                error(&stats, "Reverse target expired");
                continue;
            }
            active += 1;
            {
                let mut s = stats.lock().unwrap();
                s.peak_incoming = s.peak_incoming.max(active);
            }
            let root = root.clone();
            let complete = complete.clone();
            tokio::spawn(async move {
                let result = async {
                    result_rx
                        .await
                        .context("Reverse result dropped")?
                        .map_err(anyhow::Error::msg)?;
                    let (entry, bytes) = tokio::task::spawn_blocking(move || {
                        read_file(&root, &format!("received/{}", entry.path), MAX_FILE_BYTES)
                            .map(|bytes| (entry, bytes))
                    })
                    .await??;
                    ensure!(
                        bytes.len() as u64 == entry.size && sha256_hex(&bytes) == entry.sha256,
                        "Reverse hash mismatch"
                    );
                    Ok(entry)
                }
                .await;
                let _ = complete.send((file_id, result)).await;
            });
        }
        if !active_session.is_empty() && accepted.is_empty() && pending.is_empty() && active == 0 {
            let success = !failed && good.len() == manifest.count;
            let mut s = stats.lock().unwrap();
            s.first_upload_event_to_verified_save_ms = started.map(|t| t.elapsed().as_millis());
            s.reverse_finished_unix_ms = Some(wall_time());
            s.reverse_disk_verified = success;
            drop(s);
            log(json!({"phase":"reverse-finished","success":success,"verifiedFiles":good.len()}));
            if let Some(done) = done.take() {
                let _ = done.send(if success {
                    Ok(())
                } else {
                    Err(anyhow::anyhow!("Reverse file verification failed"))
                });
            }
            break;
        }
    }
    if let Some(done) = done {
        let _ = done.send(Err(anyhow::anyhow!(
            "Fixture listener ended before all reverse files were verified"
        )));
    }
}
async fn run(
    root: &Path,
    peer_port: u16,
    concurrency: usize,
    seconds: u64,
    stats: Arc<Mutex<Stats>>,
    receive_only: bool,
) -> anyhow::Result<()> {
    ensure!(peer_port > 0, "PEER_PORT must be nonzero");
    ensure!((1..=16).contains(&concurrency), "CONCURRENCY must be 1..16");
    ensure!((60..=7200).contains(&seconds), "SECONDS must be 60..7200");
    let manifest = load(root)?;
    verify(root, "source", &manifest)?;
    ensure!(
        fs::read_dir(root.join("received"))?.next().is_none(),
        "received must be empty; generate a fresh explicit ROOT for another run"
    );
    for entry in &manifest.entries {
        directory(
            root,
            Path::new(&format!("received/{}", entry.path))
                .parent()
                .unwrap()
                .to_str()
                .unwrap(),
        )?;
    }
    let cert = generate_self_signed()?;
    let discovery = LsHttpClientV2::try_new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        None,
        Some(Duration::from_secs(10)),
    )?;
    stats.lock().unwrap().info_calls += 1;
    let info = discovery
        .info(ProtocolType::Https, "127.0.0.1", peer_port)
        .await?;
    let client = Arc::new(LsHttpClientV2::try_new(
        &cert.private_key_pem,
        &cert.certificate_pem,
        Some(info.fingerprint.clone()),
        None,
    )?);
    let (event_tx, event_rx) = mpsc::channel(32);
    let (stop, rx) = oneshot::channel();
    let server = start_loopback_with_port(
        0,
        Some(TlsConfig {
            cert: cert.certificate_pem.clone(),
            private_key: cert.private_key_pem.clone(),
        }),
        ClientInfo {
            alias: ALIAS.into(),
            version: "2.2".into(),
            device_model: Some("Explicit loopback fixture".into()),
            device_type: Some(DeviceType::Headless),
            token: cert.fingerprint.clone(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx,
        }),
        WebConfig::default(),
        rx,
    )
    .await?;
    let (done_tx, done_rx) = oneshot::channel();
    let receiver = tokio::spawn(receive(
        event_rx,
        root.to_path_buf(),
        manifest.clone(),
        info.fingerprint.clone(),
        stats.clone(),
        done_tx,
    ));
    let registration = RegisterDtoV2 {
        alias: ALIAS.into(),
        version: "2.2".into(),
        device_model: Some("Explicit loopback fixture".into()),
        device_type: Some(DeviceType::Headless),
        fingerprint: cert.fingerprint,
        port: server.port(),
        protocol: ProtocolType::Https,
        download: false,
    };
    log(
        json!({"fixturePort":server.port(),"boundAddresses":server.local_addresses(),"peer":"127.0.0.1","peerPort":peer_port,"originalPeer":info,"count":manifest.count,"totalBytes":manifest.total_bytes,"concurrency":concurrency,"originalReceiveDestination":root.join("peer-downloads"),"reverseSelectDirectory":root.join("peer-downloads").join(&manifest.top_directory)}),
    );
    let work = async {
        stats.lock().unwrap().register_calls += 1;
        client
            .register(
                ProtocolType::Https,
                "127.0.0.1",
                peer_port,
                registration.clone(),
            )
            .await?;
        if receive_only {
            log(
                json!({"phase":"select-folder-in-original-send-ui","directory":root.join("source").join(&manifest.top_directory),"sendTo":ALIAS,"receiveOnly":true}),
            );
            done_rx.await.context("Reverse observer ended")??;
            return Ok::<_, anyhow::Error>(());
        }
        let files = manifest
            .entries
            .iter()
            .map(|e| {
                (
                    e.id.clone(),
                    FileDto {
                        id: e.id.clone(),
                        file_name: e.path.clone(),
                        size: e.size,
                        file_type: "application/octet-stream".into(),
                        sha256: Some(e.sha256.clone()),
                        preview: None,
                        metadata: None,
                    },
                )
            })
            .collect();
        log(
            json!({"phase":"waiting-original-approval","selectDestination":root.join("peer-downloads")}),
        );
        let wait = Instant::now();
        stats.lock().unwrap().prepare_calls += 1;
        let preparation = client
            .prepare_upload(
                ProtocolType::Https,
                "127.0.0.1",
                peer_port,
                None,
                PrepareUploadRequestDtoV2 {
                    info: registration,
                    files,
                },
                None,
                CancellationToken::new(),
            )
            .await;
        if preparation.is_err() {
            stats.lock().unwrap().prepare_failures += 1;
        }
        let preparation = preparation?;
        stats.lock().unwrap().approval_wait_ms = Some(wait.elapsed().as_millis());
        let preparation = preparation
            .response
            .context("Original peer accepted no files")?;
        ensure!(
            preparation.files.len() == manifest.count
                && manifest
                    .entries
                    .iter()
                    .all(|e| preparation.files.contains_key(&e.id)),
            "Original peer must accept every generated file"
        );
        let started = Instant::now();
        stats.lock().unwrap().forward_started_unix_ms = Some(wall_time());
        log(json!({"phase":"forward-started-after-approval"}));
        let in_flight = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let results = stream::iter(manifest.entries.clone())
            .map(|entry| {
                let client = client.clone();
                let stats = stats.clone();
                let root = root.to_path_buf();
                let session = preparation.session_id.clone();
                let token = preparation.files[&entry.id].clone();
                let in_flight = in_flight.clone();
                async move {
                    let active = in_flight.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    {
                        let mut s = stats.lock().unwrap();
                        s.peak_outgoing = s.peak_outgoing.max(active);
                    }
                    let result = async {
                        let source = entry.clone();
                        let bytes = tokio::task::spawn_blocking(move || {
                            read_file(&root, &format!("source/{}", source.path), MAX_FILE_BYTES)
                        })
                        .await??;
                        ensure!(
                            bytes.len() as u64 == entry.size && sha256_hex(&bytes) == entry.sha256,
                            "Generated source changed"
                        );
                        stats.lock().unwrap().upload_calls += 1;
                        client
                            .upload(
                                ProtocolType::Https,
                                "127.0.0.1",
                                peer_port,
                                None,
                                &session,
                                &entry.id,
                                &token,
                                localsend::reqwest::Body::from(bytes),
                                CancellationToken::new(),
                            )
                            .await?;
                        Ok::<_, anyhow::Error>(())
                    }
                    .await;
                    in_flight.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                    {
                        let mut s = stats.lock().unwrap();
                        match &result {
                            Ok(()) => {
                                s.sent_files += 1;
                                s.sent_bytes += entry.size;
                                if s.sent_files % 100 == 0 {
                                    log(json!({"forwardAcknowledged":s.sent_files}));
                                }
                            }
                            Err(_) => s.upload_failures += 1,
                        }
                    }
                    if let Err(e) = &result {
                        error(&stats, format!("{}: {e}", entry.path));
                    }
                    result
                }
            })
            .buffer_unordered(concurrency)
            .collect::<Vec<_>>()
            .await;
        {
            let mut s = stats.lock().unwrap();
            s.outgoing_body_ms = Some(started.elapsed().as_millis());
            s.forward_finished_unix_ms = Some(wall_time());
        }
        log(json!({"phase":"forward-finished-http-responses"}));
        ensure!(
            results.iter().all(Result::is_ok),
            "At least one original-v2 upload failed"
        );
        let verified = verify(root, "peer-downloads", &manifest)?;
        {
            let mut s = stats.lock().unwrap();
            s.forward_disk_verified = true;
            s.forward_verified = verified;
        }
        log(
            json!({"phase":"select-folder-in-original-send-ui","directory":root.join("peer-downloads").join(&manifest.top_directory),"sendTo":ALIAS}),
        );
        done_rx.await.context("Reverse observer ended")??;
        Ok::<_, anyhow::Error>(())
    };
    let result = tokio::time::timeout(Duration::from_secs(seconds), work)
        .await
        .unwrap_or_else(|_| Err(anyhow::anyhow!("Manual fixture run timed out")));
    let _ = stop.send(());
    server.wait_stopped().await;
    receiver.abort();
    result
}
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    ensure!(
        args.len() >= 2,
        "Usage: generate ROOT [COUNT=5000] | verify ROOT [source|received|peer-downloads] | run ROOT PEER_PORT [CONCURRENCY=4] [SECONDS=1800] | receive ROOT PEER_PORT [CONCURRENCY=4] [SECONDS=1800]"
    );
    let mode = &args[0];
    let root = root(&args[1], mode == "generate")?;
    match mode.as_str() {
        "generate" => {
            ensure!(args.len() <= 3, "Unexpected argument");
            let count = args.get(2).map(|n| n.parse()).transpose()?.unwrap_or(5000);
            let manifest = generate(&root, count)?;
            log(
                json!({"generated":manifest.count,"totalBytes":manifest.total_bytes,"manifest":root.join("manifest.json"),"sourceDirectory":root.join("source").join(manifest.top_directory),"networkStarted":false}),
            );
        }
        "verify" => {
            ensure!(args.len() <= 3, "Unexpected argument");
            let manifest = load(&root)?;
            let location = args.get(2).map(String::as_str).unwrap_or("source");
            verify(&root, location, &manifest)?;
            log(
                json!({"verified":manifest.count,"location":location,"totalBytes":manifest.total_bytes,"networkStarted":false}),
            );
        }
        "run" | "receive" => {
            ensure!(
                (3..=5).contains(&args.len()),
                "run needs explicit PEER_PORT"
            );
            ensure!(
                !root.join("result.json").exists(),
                "Result exists: use a fresh fixture ROOT"
            );
            let port = args[2].parse()?;
            let concurrency = args.get(3).map(|s| s.parse()).transpose()?.unwrap_or(4);
            let seconds = args.get(4).map(|s| s.parse()).transpose()?.unwrap_or(1800);
            let stats = Arc::new(Mutex::new(Stats::default()));
            let result = run(
                &root,
                port,
                concurrency,
                seconds,
                stats.clone(),
                mode == "receive",
            )
            .await;
            if let Err(e) = &result {
                error(&stats, e);
            }
            let mut s = stats.lock().unwrap();
            s.forward_verified.sort_by(|a, b| a.path.cmp(&b.path));
            s.reverse_verified.sort_by(|a, b| a.path.cmp(&b.path));
            let rate = |bytes: u64, ms: Option<u128>| {
                ms.filter(|ms| *ms > 0)
                    .map(|ms| bytes as f64 * 1000.0 / ms as f64)
            };
            let report = json!({"wallTimeUnixMs":wall_time(),"success":result.is_ok(),"receiveOnly":mode == "receive","concurrency":concurrency,"transport":"original-v2-per-file-https","connectionPolicy":"one pinned production LsHttpClientV2 reused; physical socket count not measured","forwardBytesPerSecond":rate(s.sent_bytes,s.outgoing_body_ms),"reverseBytesPerSecond":rate(s.received_bytes,s.first_upload_event_to_verified_save_ms),"timingBoundary":"reverse starts at first FileUpload event, includes target preparation; not first TCP byte","stats":&*s});
            create_file(
                &root.join("result.json"),
                &serde_json::to_vec_pretty(&report)?,
            )?;
            log(json!({"result":root.join("result.json"),"success":result.is_ok()}));
            result?;
        }
        _ => anyhow::bail!("Unknown mode"),
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifest_is_repeatable_unique_bounded_and_unicode() {
        let a = manifest(5000).unwrap();
        assert_eq!(a, manifest(5000).unwrap());
        assert_eq!(
            a.entries
                .iter()
                .map(|e| &e.path)
                .collect::<HashSet<_>>()
                .len(),
            5000
        );
        assert!(a.entries.iter().all(|e| e.size <= MAX_FILE_BYTES as u64
            && e.path.contains("😀")
            && e.path.contains("資料")));
        assert!(
            a.entries
                .iter()
                .any(|e| e.path.contains("資料/日本語/多层"))
        );
        assert!(manifest(0).is_err());
        assert!(manifest(MAX_FILES + 1).is_err());
    }
    #[test]
    fn traversal_absolute_and_windows_separators_are_rejected() {
        for path in [
            "../x",
            "/tmp/x",
            "a/../../x",
            "a\\x",
            "a/./b",
            "a//b",
            "C:/x",
            "",
        ] {
            assert!(safe_relative(path).is_err());
        }
    }
    #[test]
    fn generated_manifest_and_source_tampering_fail_verification() {
        let root = std::env::temp_dir().join(format!(
            "legnasend-offline-fixture-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&root).unwrap();
        let manifest = generate(&root, 7).unwrap();
        assert_eq!(verify(&root, "source", &manifest).unwrap().len(), 7);
        assert_eq!(generate(&root, 7).unwrap(), manifest);
        fs::write(
            root.join("source").join(&manifest.entries[0].path),
            b"changed",
        )
        .unwrap();
        assert!(verify(&root, "source", &manifest).is_err());
        assert!(generate(&root, 7).is_err());
        let mut altered = manifest.clone();
        altered.entries[0].path = "../outside".into();
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&altered).unwrap(),
        )
        .unwrap();
        assert!(load(&root).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn reverse_scheduler_backpressures_bursts_without_rejecting_valid_targets() {
        // No socket/listener: exercise the actual example dispatcher with an
        // in-memory event source and a deliberately delayed synthetic writer.
        let root =
            std::env::temp_dir().join(format!("legnasend-offline-queue-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let manifest = generate(&root, 96).unwrap();
        for entry in &manifest.entries {
            directory(
                &root,
                Path::new(&format!("received/{}", entry.path))
                    .parent()
                    .unwrap()
                    .to_str()
                    .unwrap(),
            )
            .unwrap();
        }
        let (events, rx) = mpsc::channel(32);
        let (done, finished) = oneshot::channel();
        let stats = Arc::new(Mutex::new(Stats::default()));
        let receiver = tokio::spawn(receive(
            rx,
            root.clone(),
            manifest.clone(),
            "peer".into(),
            stats.clone(),
            done,
        ));
        let (decision_tx, decision) = oneshot::channel();
        let files: HashMap<_, _> = manifest
            .entries
            .iter()
            .map(|e| {
                (
                    e.id.clone(),
                    FileDto {
                        id: e.id.clone(),
                        file_name: e.path.clone(),
                        size: e.size,
                        file_type: "application/octet-stream".into(),
                        sha256: None,
                        preview: None,
                        metadata: None,
                    },
                )
            })
            .collect();
        events
            .send(ServerEventV2::PrepareUpload {
                session_id: "session".into(),
                ip: localsend::http::server::PeerIp {
                    ip: std::net::Ipv4Addr::LOCALHOST.into(),
                    scope_id: None,
                },
                info: RegisterDtoV2 {
                    alias: "offline".into(),
                    version: "2.2".into(),
                    device_model: None,
                    device_type: None,
                    fingerprint: "peer".into(),
                    port: 53317,
                    protocol: ProtocolType::Https,
                    download: false,
                },
                cert_fingerprint: Some("peer".into()),
                files: files.clone(),
                decision_tx,
            })
            .await
            .unwrap();
        assert!(
            matches!(decision.await.unwrap(),PrepareUploadDecisionV2::Accept(ids) if ids.len()==96)
        );
        let mut writers = vec![];
        for (index, entry) in manifest.entries.iter().enumerate() {
            let (target_tx, target) = oneshot::channel();
            let data = payload(index, &entry.path);
            writers.push(tokio::spawn(async move {
                let FileUploadTarget::CachedPath {
                    path, result_tx, ..
                } = target.await.unwrap()
                else {
                    panic!("fixture bypassed transactional target")
                };
                tokio::time::sleep(Duration::from_millis(15)).await;
                tokio::fs::write(path, data).await.unwrap();
                result_tx.send(Ok(())).unwrap();
            }));
            events
                .send(ServerEventV2::FileUpload {
                    session_id: "session".into(),
                    file_id: entry.id.clone(),
                    file: files[&entry.id].clone(),
                    target_tx,
                })
                .await
                .unwrap();
        }
        tokio::time::timeout(Duration::from_secs(5), finished)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        for writer in writers {
            writer.await.unwrap();
        }
        receiver.await.unwrap();
        {
            let s = stats.lock().unwrap();
            assert_eq!(s.received_files, 96);
            assert_eq!(s.incoming_failures, 0);
            assert_eq!(s.peak_incoming, 8);
            assert_eq!(s.peak_pending_targets, 32);
            assert!(s.reverse_disk_verified);
        }
        fs::remove_dir_all(root).unwrap();
    }
}
