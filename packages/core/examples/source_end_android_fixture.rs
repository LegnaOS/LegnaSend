//! Run-owned, loopback-only real receiver behind a transparent interruption gate.
//! No production route or original LocalSend wire behavior is replaced.
use anyhow::{Context, ensure};
use localsend::{
    crypto::cert::generate_self_signed,
    http::{
        server::{
            ServerConfigV2, ServerHandle, TlsConfig,
            common::save::FileUploadTarget,
            start_loopback_with_port,
            v2::{PrepareUploadDecisionV2, ServerEventV2},
            web::WebConfig,
        },
        state::ClientInfo,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{Semaphore, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;
const NAME: &str = "LegnaSend-source-end-fixture.bin";
const ALIAS: &str = "LegnaSend Source End Fixture";
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    version: u32,
    name: String,
    size: u64,
    sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Identity {
    cert: String,
    key: String,
    fingerprint: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    revision: u64,
    action: String,
}
fn private_write(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn load<T: serde::de::DeserializeOwned>(path: &Path, limit: u64) -> anyhow::Result<T> {
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= limit,
        "Invalid fixture metadata"
    );
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= limit as usize,
        "Fixture metadata over budget"
    );
    Ok(serde_json::from_slice(&bytes)?)
}
fn generate(root: &Path, mib: u64) -> anyhow::Result<()> {
    ensure!((4..=256).contains(&mib), "MiB must be 4..256");
    ensure!(!root.exists(), "ROOT must be new");
    let mut b = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o700);
    }
    b.create(root)?;
    fs::create_dir(root.join("received"))?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(root.join(NAME))?;
    let buffer: Vec<u8> = (0..256 * 1024)
        .map(|n| ((n * 17 + 29) % 251) as u8)
        .collect();
    let mut hash = Sha256::new();
    for _ in 0..mib * 4 {
        file.write_all(&buffer)?;
        hash.update(&buffer);
    }
    file.sync_all()?;
    let manifest = Manifest {
        version: 1,
        name: NAME.into(),
        size: mib * 1024 * 1024,
        sha256: hash.finalize().iter().map(|b|format!("{b:02x}")).collect::<String>(),
    };
    private_write(
        &root.join("manifest.json"),
        &serde_json::to_vec_pretty(&manifest)?,
    )?;
    let cert = generate_self_signed()?;
    let identity = Identity {
        cert: cert.certificate_pem,
        key: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    };
    private_write(&root.join("identity.json"), &serde_json::to_vec(&identity)?)?;
    println!(
        "{}",
        json!({"event":"generated","name":NAME,"size":manifest.size,"sha256":manifest.sha256,"fingerprint":identity.fingerprint})
    );
    Ok(())
}
struct Gate {
    online: AtomicBool,
    epoch: Mutex<CancellationToken>,
    tripped: AtomicBool,
    progress: AtomicU64,
    active: AtomicUsize,
    receiver_port: AtomicU16,
    stop: CancellationToken,
}
impl Gate {
    fn offline(&self) {
        self.online.store(false, Ordering::Release);
        let mut token = self.epoch.lock().unwrap();
        token.cancel();
        *token = CancellationToken::new();
    }
    fn online(&self) {
        self.online.store(true, Ordering::Release);
    }
}
struct Receiver {
    handle: Arc<ServerHandle>,
    stop: Option<oneshot::Sender<()>>,
}
async fn receiver(
    root: PathBuf,
    manifest: Manifest,
    identity: Identity,
    peer: String,
    gate: Arc<Gate>,
) -> anyhow::Result<Receiver> {
    let (events, mut rx) = mpsc::channel(32);
    let (stop, stopped) = oneshot::channel();
    let handle = Arc::new(
        start_loopback_with_port(
            0,
            Some(TlsConfig {
                cert: identity.cert,
                private_key: identity.key,
            }),
            ClientInfo {
                alias: ALIAS.into(),
                version: "2.2".into(),
                device_model: Some("Bounded Android outbox fixture".into()),
                device_type: None,
                token: identity.fingerprint,
            },
            None,
            Some(ServerConfigV2 {
                pin: None,
                verify_checksums: true,
                event_tx: events,
            }),
            WebConfig::default(),
            stopped,
        )
        .await?,
    );
    gate.receiver_port.store(handle.port(), Ordering::Release);
    let weak = Arc::downgrade(&handle);
    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                ServerEventV2::PrepareUpload {
                    ip,
                    cert_fingerprint,
                    files,
                    decision_tx,
                    ..
                } => {
                    let matches = ip.to_string().starts_with("127.")
                        && cert_fingerprint.as_deref() == Some(&peer)
                        && files.len() == 1
                        && files.values().all(|f| {
                            f.file_name == manifest.name
                                && f.size == manifest.size
                                && f.sha256
                                    .as_ref()
                                    .is_some_and(|s| s.eq_ignore_ascii_case(&manifest.sha256))
                        });
                    println!(
                        "{}",
                        json!({"event":"approval","accepted":matches,"peerMatches":cert_fingerprint.as_deref()==Some(&peer),"files":files.len(),"requiresPrepareChecksum":true})
                    );
                    let ids = files.keys().cloned().collect();
                    let _ = decision_tx.send(if matches {
                        PrepareUploadDecisionV2::AcceptDurable {
                            file_ids: ids,
                            resumable_file_ids: files.keys().cloned().collect(),
                            durable_file_ids: files.keys().cloned().collect(),
                        }
                    } else {
                        PrepareUploadDecisionV2::Decline
                    });
                }
                ServerEventV2::FileUploadRecovery {
                    session_id,
                    file_id,
                    attempt_id,
                    file,
                    target_tx,
                } => {
                    if file.file_name != manifest.name || file.size != manifest.size {
                        continue;
                    }
                    let Some(handle) = weak.upgrade() else {
                        break;
                    };
                    let lookup = match handle
                        .lookup_receive_recovery_target(
                            &session_id,
                            &file_id,
                            &attempt_id,
                            root.join("received").to_string_lossy().into_owned(),
                            file.file_name.clone(),
                        )
                        .await
                    {
                        Ok(v) => v,
                        Err(_) => {
                            println!("{}", json!({"event":"targetRejected"}));
                            continue;
                        }
                    };
                    let path = lookup
                        .path
                        .map(PathBuf::from)
                        .unwrap_or_else(|| root.join("received").join(&manifest.name));
                    let (result_tx, result) = oneshot::channel();
                    let (progress_tx, mut progress) = mpsc::channel(8);
                    gate.active.fetch_add(1, Ordering::AcqRel);
                    if target_tx
                        .send(FileUploadTarget::CachedPath {
                            path,
                            result_tx,
                            progress_tx: Some(progress_tx),
                        })
                        .is_err()
                    {
                        gate.active.fetch_sub(1, Ordering::AcqRel);
                        continue;
                    }
                    let control = gate.clone();
                    tokio::spawn(async move {
                        while let Some(bytes) = progress.recv().await {
                            control.progress.store(bytes, Ordering::Release);
                            if bytes >= 1024 * 1024 && !control.tripped.swap(true, Ordering::AcqRel)
                            {
                                control.offline();
                                println!(
                                    "{}",
                                    json!({"event":"networkInterrupted","confirmedBytes":bytes,"receiverKeptRunning":true})
                                );
                            }
                        }
                    });
                    let control = gate.clone();
                    tokio::spawn(async move {
                        let success = matches!(result.await, Ok(Ok(())));
                        control.active.fetch_sub(1, Ordering::AcqRel);
                        println!(
                            "{}",
                            json!({"event":"logicalReceiveEnded","success":success,"actualProgress":control.progress.load(Ordering::Acquire)})
                        );
                    });
                }
                ServerEventV2::FileUpload { target_tx, .. } => {
                    drop(target_tx);
                    println!("{}", json!({"event":"unexpectedLegacyUploadRejected"}));
                }
                _ => {}
            }
        }
    });
    Ok(Receiver {
        handle,
        stop: Some(stop),
    })
}
async fn proxy(listener: TcpListener, gate: Arc<Gate>) {
    let slots = Arc::new(Semaphore::new(8));
    loop {
        let connection = tokio::select! {_=gate.stop.cancelled()=>break,c=listener.accept()=>c};
        let Ok((mut incoming, _)) = connection else {
            break;
        };
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        if !gate.online.load(Ordering::Acquire) {
            continue;
        }
        let epoch = gate.epoch.lock().unwrap().clone();
        let port = gate.receiver_port.load(Ordering::Acquire);
        let stopped = gate.stop.clone();
        tokio::spawn(async move {
            let _permit = permit;
            tokio::select! {_=epoch.cancelled()=>{},_=stopped.cancelled()=>{},_=async {
                if let Ok(mut outgoing)=TcpStream::connect(("127.0.0.1",port)).await {let _=tokio::io::copy_bidirectional(&mut incoming,&mut outgoing).await;}
            }=>{}}
        });
    }
}
fn snapshot(root: &Path, gate: &Gate) -> anyhow::Result<Value> {
    let mut caches = Vec::new();
    let mut total = 0;
    for entry in fs::read_dir(root.join("received"))?.take(16) {
        let entry = entry?;
        let m = fs::symlink_metadata(entry.path())?;
        if !m.is_file() || m.file_type().is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(".legnasend-receive-")
            && (name.ends_with(".ls") || name.ends_with(".part"))
        {
            total += m.len();
            caches.push(
                json!({"kind":if name.ends_with(".ls"){"cache"}else{"staging"},"bytes":m.len()}),
            );
        }
    }
    let registry = root.join("registry.resume");
    let mut phases = Vec::new();
    let mut proofs = Vec::new();
    if registry.is_dir() {
        for entry in fs::read_dir(&registry)?.take(130) {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.len() == 64
                && name.bytes().all(|b| b.is_ascii_hexdigit())
                && entry.file_type()?.is_dir()
            {
                if let Ok(v) = load::<Value>(&entry.path().join("state.json"), 65536) {
                    phases.push(v["value"]["phase"].clone());
                }
            }
        }
        if let Ok(entries) = fs::read_dir(registry.join(".source-end")) {
            for entry in entries.take(256) {
                let entry = entry?;
                if let Ok(v) = load::<Value>(&entry.path(), 65536) {
                    if v["value"]["proof"].is_object() {
                        let p = &v["value"]["proof"];
                        proofs.push(json!({"outcome":p["outcome"],"receiptId":p["receiptId"],"removedFiles":p["removedFiles"],"unlinkedBytes":p["unlinkedBytes"]}));
                    }
                }
            }
        }
    }
    Ok(
        json!({"online":gate.online.load(Ordering::Acquire),"tripped":gate.tripped.load(Ordering::Acquire),"activeWriters":gate.active.load(Ordering::Acquire),"confirmedBytes":gate.progress.load(Ordering::Acquire),"cacheFiles":caches,"actualPartialBytes":total,"recordPhases":phases,"cleanupProofs":proofs}),
    )
}
async fn run(root: &Path, peer: String, port: u16, seconds: u64) -> anyhow::Result<()> {
    ensure!(
        (60..=7200).contains(&seconds),
        "Run deadline must be 60..7200 seconds"
    );
    ensure!(
        peer.len() == 64 && peer.bytes().all(|b| b.is_ascii_hexdigit()),
        "Expected SHA256 certificate fingerprint required"
    );
    ensure!(
        !fs::symlink_metadata(root)?.file_type().is_symlink(),
        "ROOT cannot be a link"
    );
    let root = fs::canonicalize(root)?;
    let manifest: Manifest = load(&root.join("manifest.json"), 4096)?;
    ensure!(
        manifest.version == 1
            && manifest.name == NAME
            && (4 * 1024 * 1024..=256 * 1024 * 1024).contains(&manifest.size),
        "Invalid generated manifest"
    );
    let identity: Identity = load(&root.join("identity.json"), 16384)?;
    let mut file = fs::File::open(root.join(NAME))?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    let mut size = 0;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        hash.update(&buffer[..n]);
    }
    ensure!(
        size == manifest.size && hash.finalize().iter().map(|b|format!("{b:02x}")).collect::<String>() == manifest.sha256,
        "Generated source changed"
    );
    let lease = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(root.join("run.lock"))
        .context("ROOT was already run; use a fresh run root")?;
    lease.try_lock().context("Fixture lease busy")?;
    localsend::receive_registry::configure(root.join("registry"))?;
    let gate = Arc::new(Gate {
        online: AtomicBool::new(true),
        epoch: Mutex::new(CancellationToken::new()),
        tripped: AtomicBool::new(false),
        progress: AtomicU64::new(0),
        active: AtomicUsize::new(0),
        receiver_port: AtomicU16::new(0),
        stop: CancellationToken::new(),
    });
    let mut server = receiver(
        root.clone(),
        manifest.clone(),
        identity.clone(),
        peer.to_ascii_uppercase(),
        gate.clone(),
    )
    .await?;
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    let port = listener.local_addr()?.port();
    tokio::spawn(proxy(listener, gate.clone()));
    let ready = json!({"event":"ready","alias":ALIAS,"protocol":"https","host":"127.0.0.1","port":port,"fingerprint":identity.fingerprint,"name":manifest.name,"size":manifest.size,"sha256":manifest.sha256,"deadlineSeconds":seconds});
    private_write(
        &root.join("ready.json"),
        &serde_json::to_vec_pretty(&ready)?,
    )?;
    println!("{ready}");
    let end = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let mut revision = 0;
    while tokio::time::Instant::now() < end {
        if let Ok(command) = load::<Control>(&root.join("control.json"), 4096) {
            if command.revision > revision {
                revision = command.revision;
                let mut accepted = true;
                match command.action.as_str() {
                    "offline" => gate.offline(),
                    "online" => gate.online(),
                    "status" => {}
                    "restartReceiver" => {
                        if gate.active.load(Ordering::Acquire) != 0 {
                            accepted = false;
                        } else {
                            gate.offline();
                            server.stop.take();
                            server.handle.wait_stopped().await;
                            server = receiver(
                                root.clone(),
                                manifest.clone(),
                                identity.clone(),
                                peer.to_ascii_uppercase(),
                                gate.clone(),
                            )
                            .await?;
                        }
                    }
                    "quit" => break,
                    _ => accepted = false,
                }
                println!(
                    "{}",
                    json!({"event":"control","revision":revision,"accepted":accepted})
                );
            }
        }
        let value = snapshot(&root, &gate)?;
        let tmp = root.join("status.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&value)?)?;
        fs::rename(tmp, root.join("status.json"))?;
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    gate.offline();
    gate.stop.cancel();
    server.stop.take();
    server.handle.wait_stopped().await;
    println!(
        "{}",
        json!({"event":"fixtureStopped","note":"deadline/quit ends receiver; active receive may be explicitly cancelled"})
    );
    Ok(())
}
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    ensure!(
        args.len() >= 3,
        "generate ROOT [MiB] | run ROOT EXPECTED_APP_FINGERPRINT [PORT] [SECONDS]"
    );
    let root = Path::new(&args[2]);
    ensure!(root.is_absolute(), "Absolute new ROOT required");
    match args[1].as_str() {
        "generate" => generate(root, args.get(3).map_or(Ok(16), |s| s.parse())?),
        "run" => {
            run(
                root,
                args.get(3)
                    .context("Expected App certificate fingerprint required")?
                    .clone(),
                args.get(4).map_or(Ok(0), |s| s.parse())?,
                args.get(5).map_or(Ok(1200), |s| s.parse())?,
            )
            .await
        }
        _ => anyhow::bail!("Unknown fixture operation"),
    }
}
