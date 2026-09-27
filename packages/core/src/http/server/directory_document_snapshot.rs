//! Capture explicitly selected provider files; never a provider content-version claim.
use super::{DirectoryRegistry, Workspace, documents, snapshot, validate_relative};
use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    sync::Arc,
};
use tokio_util::sync::CancellationToken;

const BUFFER: usize = 256 * 1024;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    mode: String,
    files: Vec<Selection>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    id: String,
}

fn check(
    ws: &Workspace,
    stopped: &CancellationToken,
    cancel: &CancellationToken,
) -> anyhow::Result<()> {
    anyhow::ensure!(!stopped.is_cancelled(), "server_stopped");
    anyhow::ensure!(
        !cancel.is_cancelled() && !ws.stopped.is_cancelled() && !ws.version_stopped.is_cancelled(),
        "workspace_changed"
    );
    Ok(())
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.contains('/')
        && validate_relative(name).is_ok()
        && !name.contains(['<', '>', '"', '|', '?', '*'])
}
struct OwnedStage {
    root: Dir,
    created: Vec<(String, std::fs::Metadata)>,
    committed: bool,
}
impl OwnedStage {
    fn create(&mut self, name: &str) -> anyhow::Result<File> {
        let mut options = OpenOptions::new();
        options
            .write(true)
            .create_new(true)
            .follow(FollowSymlinks::No);
        let file = self
            .root
            .open_with(name, &options)
            .map_err(|_| anyhow::anyhow!("capture_storage"))?
            .into_std();
        let metadata = file
            .metadata()
            .map_err(|_| anyhow::anyhow!("capture_storage"))?;
        self.created.push((name.into(), metadata));
        Ok(file)
    }
}
impl Drop for OwnedStage {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        for (name, original) in &self.created {
            let mut options = OpenOptions::new();
            options.read(true).follow(FollowSymlinks::No);
            let Ok(file) = self.root.open_with(name, &options) else {
                continue;
            };
            let Ok(current) = file.into_std().metadata() else {
                continue;
            };
            #[cfg(unix)]
            let same = {
                use std::os::unix::fs::MetadataExt;
                current.is_file()
                    && current.dev() == original.dev()
                    && current.ino() == original.ino()
                    && current.created().ok() == original.created().ok()
            };
            // Native document handles are currently Android-only. On an unknown
            // host identity model, leave cleanup to the existing registered store.
            #[cfg(not(unix))]
            let same = {
                let _ = (current, original);
                false
            };
            if same {
                let _ = self.root.remove_file(name);
            }
        }
    }
}
fn digest(hasher: Sha256) -> String {
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn copy_checked(
    mut source: File,
    mut target: File,
    size: u64,
    check: impl Fn() -> anyhow::Result<()>,
) -> anyhow::Result<String> {
    let before = source
        .metadata()
        .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
    anyhow::ensure!(before.is_file() && before.len() == size, "source_changed");
    source
        .seek(SeekFrom::Start(0))
        .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
    let mut buffer = vec![0; BUFFER];
    let mut first = Sha256::new();
    let mut count = 0u64;
    loop {
        check()?;
        let n = source
            .read(&mut buffer)
            .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
        if n == 0 {
            break;
        }
        count = count
            .checked_add(n as u64)
            .ok_or_else(|| anyhow::anyhow!("source_changed"))?;
        anyhow::ensure!(count <= size, "source_changed");
        first.update(&buffer[..n]);
        target
            .write_all(&buffer[..n])
            .map_err(|_| anyhow::anyhow!("capture_storage"))?;
    }
    anyhow::ensure!(count == size, "source_changed");
    target
        .sync_all()
        .map_err(|_| anyhow::anyhow!("capture_storage"))?;
    check()?;
    source
        .seek(SeekFrom::Start(0))
        .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
    let mut second = Sha256::new();
    count = 0;
    loop {
        check()?;
        let n = source
            .read(&mut buffer)
            .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
        if n == 0 {
            break;
        }
        count = count
            .checked_add(n as u64)
            .ok_or_else(|| anyhow::anyhow!("source_changed"))?;
        anyhow::ensure!(count <= size, "source_changed");
        second.update(&buffer[..n]);
    }
    let first = digest(first);
    let after = source
        .metadata()
        .map_err(|_| anyhow::anyhow!("source_unavailable"))?;
    anyhow::ensure!(
        count == size
            && after.len() == size
            && before.modified().ok() == after.modified().ok()
            && first == digest(second),
        "source_changed"
    );
    check()?;
    Ok(first)
}
pub(super) async fn capture(
    registry: Arc<DirectoryRegistry>,
    ws: Arc<Workspace>,
    input: &str,
    destination: String,
    stopped: CancellationToken,
) -> anyhow::Result<String> {
    anyhow::ensure!(input.len() <= 64 * 1024, "selection_too_large");
    let input: Input =
        serde_json::from_str(input).map_err(|_| anyhow::anyhow!("invalid_selection"))?;
    anyhow::ensure!(
        input.mode == "documentSnapshot" && !input.files.is_empty() && input.files.len() <= 128,
        "invalid_selection"
    );
    let mut ids = HashSet::new();
    for item in &input.files {
        anyhow::ensure!(
            uuid::Uuid::parse_str(&item.id)
                .is_ok_and(|v| v.get_version_num() == 4 && v.to_string() == item.id)
                && ids.insert(&item.id),
            "invalid_selection"
        );
    }
    let permit = snapshot::acquire_capture()?;
    let cancel = ws.version_stopped.child_token();
    let _cancel_on_drop = cancel.clone().drop_guard();
    let runtime = tokio::runtime::Handle::current();
    tokio::task::spawn_blocking(move || -> anyhow::Result<String> {
        let _permit=permit;
        check(&ws,&stopped,&cancel)?;
        let root=Dir::open_ambient_dir(destination,ambient_authority()).map_err(|_|anyhow::anyhow!("capture_storage"))?;
        let mut stage=OwnedStage{root,created:vec![],committed:false};
        let mut result=Vec::new();let mut names=HashSet::new();let mut total=0u64;
        for (index,item) in input.files.into_iter().enumerate() {
            check(&ws,&stopped,&cancel)?;
            let (source,metadata)=runtime.block_on(async { tokio::select! { biased;
                _=stopped.cancelled()=>Err(anyhow::anyhow!("server_stopped")),
                _=cancel.cancelled()=>Err(anyhow::anyhow!("workspace_changed")),
                value=documents::open_file(&registry,&ws,&item.id,Some(&cancel))=>value.map_err(|_|anyhow::anyhow!("source_unavailable")),
            } })?;
            check(&ws,&stopped,&cancel)?;
            anyhow::ensure!(valid_name(&metadata.name),"invalid_file_name");
            anyhow::ensure!(names.insert(metadata.name.to_lowercase()),"duplicate_file_name");
            total=total.checked_add(metadata.size).filter(|n|*n<=9_007_199_254_740_991).ok_or_else(||anyhow::anyhow!("selection_too_large"))?;
            #[cfg(unix)]
            { let space=rustix::fs::fstatvfs(&stage.root).map_err(|_|anyhow::anyhow!("capture_storage"))?;
              anyhow::ensure!(u128::from(space.f_bavail)*u128::from(space.f_frsize)>=u128::from(metadata.size),"capture_storage"); }
            let name=format!("source-{index}");let target=stage.create(&name)?;
            let sha=copy_checked(source,target,metadata.size,||check(&ws,&stopped,&cancel))?;
            result.push(json!({"name":metadata.name,"size":metadata.size,"source":name,"sha256":sha}));
        }
        check(&ws,&stopped,&cancel)?;stage.committed=true;
        Ok(json!({"files":result}).to_string())
    }).await.map_err(|_|anyhow::anyhow!("capture_storage"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn second_pass_rejects_same_length_source_changes_and_keeps_budget_buffer_bounded() {
        let root =
            std::env::temp_dir().join(format!("capture-double-hash-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let source = root.join("source");
        std::fs::write(&source, b"first").unwrap();
        let checks = std::cell::Cell::new(0);
        let result = copy_checked(
            File::open(&source).unwrap(),
            File::create(root.join("copy")).unwrap(),
            5,
            || {
                checks.set(checks.get() + 1);
                if checks.get() == 4 {
                    std::fs::write(&source, b"other").unwrap();
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert_eq!(std::fs::read(root.join("copy")).unwrap(), b"first");
        assert_eq!(BUFFER, 262144);
        std::fs::remove_dir_all(root).unwrap();
    }
}
