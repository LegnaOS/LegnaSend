//! Verify browser-generated fixture containers with the native storage engine.
//! The root must contain checkpoint.json, checkpoint.ls and generated demo.txt.
use localsend::download_cache::{CacheIdentity, DownloadCache};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--create-native") {
        return create_native(PathBuf::from(
            std::env::args()
                .nth(2)
                .expect("native fixture root required"),
        ));
    }
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("generated fixture root required"),
    );
    let identity: CacheIdentity =
        serde_json::from_slice(&std::fs::read(root.join("checkpoint.json"))?)?;
    let mut copy = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(root.join("native-complete.ls"))?;
    std::io::copy(&mut File::open(root.join("checkpoint.ls"))?, &mut copy)?;
    let (mut cache, recovery) = DownloadCache::resume(copy, &identity)?;
    let missing: Vec<_> = cache.missing_chunks().collect();
    let mut input = File::open(root.join("demo.txt"))?;
    for index in missing {
        let start = u64::from(index) * u64::from(identity.chunk_size);
        let length = (identity.size - start).min(u64::from(identity.chunk_size));
        let mut bytes = vec![0; length as usize];
        input.seek(SeekFrom::Start(start))?;
        input.read_exact(&mut bytes)?;
        cache.commit_chunk(index, &bytes)?;
    }
    let mut output = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(root.join("native-restored.bin"))?;
    let receipt = cache.export(&mut output)?;
    println!(
        "{}",
        serde_json::json!({"recoveredBytes":recovery.committed_bytes,"recoveredChunks":recovery.committed_chunks,"restoredBytes":receipt.bytes,"sha256":receipt.sha256})
    );
    Ok(())
}

/// Generate a formal header and committed records through the production Rust
/// writer, independently of browser serialization, for platform reader checks.
fn create_native(root: PathBuf) -> anyhow::Result<()> {
    std::fs::create_dir_all(&root)?;
    let bytes = "LegnaSend native cache fixture · 中文 % 😀".as_bytes();
    let identity = CacheIdentity {
        task_id: uuid::Uuid::new_v4().to_string(),
        source_id: "native-header-fixture".into(),
        resource_id: "original-payload".into(),
        version: "native-fixture-v1".into(),
        file_name: "中文 %.txt".into(),
        size: bytes.len() as u64,
        chunk_size: localsend::download_cache::MIN_CHUNK_SIZE,
        created_unix_ms: 1,
        sha256: Some(localsend::crypto::hash::sha256_hex(bytes)),
    };
    let fresh = |name: &str| {
        OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(root.join(name))
    };
    use std::io::Write;
    fresh("native-identity.json")?.write_all(&serde_json::to_vec(&identity)?)?;
    let mut cache = DownloadCache::create(fresh("native-created.ls")?, identity)?;
    cache.commit_chunk(0, bytes)?;
    let receipt = cache.export(&mut fresh("native-original.bin")?)?;
    anyhow::ensure!(std::fs::read(root.join("native-original.bin"))? == bytes);
    println!(
        "{}",
        serde_json::json!({"bytes": receipt.bytes, "sha256": receipt.sha256})
    );
    Ok(())
}
