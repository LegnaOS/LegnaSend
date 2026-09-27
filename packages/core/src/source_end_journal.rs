//! Private host-only control journal held by an opaque process lease.
//! Paths/secrets never enter public APIs or diagnostic error strings.
use cap_fs_ext::{DirExt, FollowSymlinks, MetadataExt, OpenOptionsFollowExt};
#[cfg(not(target_vendor = "apple"))]
use cap_std::ambient_authority;
use cap_std::fs::{Dir, DirBuilder, OpenOptions};
use std::{
    ffi::OsString,
    fs::File,
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
    sync::Mutex,
};
const LIMIT: usize = 2 * 1024 * 1024;
const DIRECTORY: &str = "source-end-control";
const JOURNAL: &str = "journal.json";
const LOCK: &str = "journal.lock";
fn invalid() -> io::Error {
    io::Error::other("Invalid private control journal")
}
fn error(error: io::Error) -> anyhow::Error {
    // Diagnostics retain only typed OS facts, never a path, payload or token.
    anyhow::anyhow!(
        "source_end_journal_unavailable(kind={:?}, errno={})",
        error.kind(),
        error
            .raw_os_error()
            .map_or_else(|| "none".into(), |code| code.to_string())
    )
}
fn identity(file: &File) -> io::Result<same_file::Handle> {
    same_file::Handle::from_file(file.try_clone()?)
}
struct Link {
    parent: Dir,
    name: OsString,
    identity: same_file::Handle,
}
#[cfg(target_vendor = "apple")]
struct AppleRoot {
    path: PathBuf,
    identity: same_file::Handle,
}
struct Anchored {
    directory: Dir,
    chain: Vec<Link>,
    #[cfg(target_vendor = "apple")]
    root: AppleRoot,
}
fn private_directory(dir: &Dir) -> io::Result<()> {
    let m = dir.try_clone()?.into_std_file().metadata()?;
    if !m.is_dir() {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o777 != 0o700 {
            return Err(invalid());
        }
    }
    Ok(())
}
fn safe_file(file: &File) -> io::Result<()> {
    let m = cap_std::fs::Metadata::from_file(file)?;
    if !m.is_file() || m.nlink() != 1 {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = file.metadata()?;
        if m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o777 != 0o600 {
            return Err(invalid());
        }
    }
    Ok(())
}
fn options(write: bool) -> OpenOptions {
    let mut o = OpenOptions::new();
    o.read(true).write(write).follow(FollowSymlinks::No);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NONBLOCK).mode(0o600);
    }
    o
}
fn descend(root: Dir, name: &std::ffi::OsStr, chain: &mut Vec<Link>) -> io::Result<Dir> {
    let next = root.open_dir_nofollow(name)?;
    chain.push(Link {
        parent: root,
        name: name.to_owned(),
        identity: identity(&next.try_clone()?.into_std_file())?,
    });
    Ok(next)
}
fn open_directory(path: &str) -> io::Result<Anchored> {
    if path.len() > 16 * 1024 {
        return Err(invalid());
    }
    let path = Path::new(path);
    if !path.is_absolute() || path.file_name() != Some(JOURNAL.as_ref()) {
        return Err(invalid());
    }
    let parent = path.parent().ok_or_else(invalid)?;
    if parent.file_name() != Some(DIRECTORY.as_ref()) {
        return Err(invalid());
    }
    let outer = parent.parent().ok_or_else(invalid)?;
    #[cfg(not(target_vendor = "apple"))]
    let mut anchor = PathBuf::new();
    let mut children = Vec::new();
    for c in outer.components() {
        match c {
            Component::Prefix(_) | Component::RootDir => {
                #[cfg(not(target_vendor = "apple"))]
                anchor.push(c.as_os_str());
            }
            Component::Normal(n) => children.push(n),
            _ => return Err(invalid()),
        }
    }
    if children.len() > 128 {
        return Err(invalid());
    }
    #[cfg(target_vendor = "apple")]
    let root = crate::receive_scope_policy::CoordinatedRoot::open(outer)?.open_parent(outer)?;
    #[cfg(target_vendor = "apple")]
    let root_identity = AppleRoot {
        path: outer.into(),
        identity: identity(&root.try_clone()?.into_std_file())?,
    };
    #[cfg(not(target_vendor = "apple"))]
    let mut root = Dir::open_ambient_dir(anchor, ambient_authority())?;
    let mut chain = Vec::new();
    #[cfg(not(target_vendor = "apple"))]
    for name in children {
        root = descend(root, name, &mut chain)?;
    }
    let mut b = DirBuilder::new();
    #[cfg(unix)]
    {
        use cap_std::fs::DirBuilderExt;
        b.mode(0o700);
    }
    match root.create_dir_with(DIRECTORY, &b) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let directory = descend(root, DIRECTORY.as_ref(), &mut chain)?;
    private_directory(&directory)?;
    Ok(Anchored {
        directory,
        chain,
        #[cfg(target_vendor = "apple")]
        root: root_identity,
    })
}
impl Anchored {
    fn check(&self) -> io::Result<()> {
        #[cfg(target_vendor = "apple")]
        {
            // App Sandbox grants the private root, not read access to every
            // ancestor. Reopen exactly that root with kernel-wide no-follow
            // lookup and compare its pinned identity before any journal I/O.
            let actual = crate::receive_scope_policy::CoordinatedRoot::open(&self.root.path)?
                .open_parent(&self.root.path)?
                .into_std_file();
            if identity(&actual)? != self.root.identity {
                return Err(invalid());
            }
        }
        for link in &self.chain {
            let actual = link.parent.open_dir_nofollow(&link.name)?.into_std_file();
            if identity(&actual)? != link.identity {
                return Err(invalid());
            }
        }
        private_directory(&self.directory)
    }
}
struct State {
    anchor: Anchored,
    lock: File,
    lock_identity: same_file::Handle,
    poisoned: bool,
}
impl State {
    fn check(&self) -> io::Result<()> {
        if self.poisoned {
            return Err(invalid());
        }
        self.anchor.check()?;
        safe_file(&self.lock)?;
        let current = self
            .anchor
            .directory
            .open_with(LOCK, &options(true))?
            .into_std();
        safe_file(&current)?;
        if identity(&current)? != self.lock_identity {
            return Err(invalid());
        }
        Ok(())
    }
}
/// All operations use the same no-follow directory chain and actual lock FD.
/// Closing waits for an in-flight worker; no fd-number or path-based lock table.
pub struct Lease {
    state: Mutex<Option<State>>,
}
pub fn open(path: &str) -> anyhow::Result<Lease> {
    open_inner(path, || Ok(()))
}
fn open_inner(path: &str, before_lock: impl FnOnce() -> io::Result<()>) -> anyhow::Result<Lease> {
    (|| -> io::Result<_> {
        let anchor = open_directory(path)?;
        anchor.check()?;
        let mut create = options(true);
        create.create_new(true);
        let lock = match anchor.directory.open_with(LOCK, &create) {
            Ok(f) => f.into_std(),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                anchor.directory.open_with(LOCK, &options(true))?.into_std()
            }
            Err(e) => return Err(e),
        };
        safe_file(&lock)?;
        before_lock()?;
        crate::file_lock::try_exclusive_strict(&lock).map_err(io::Error::other)?;
        let state = State {
            lock_identity: identity(&lock)?,
            anchor,
            lock,
            poisoned: false,
        };
        state.check()?;
        Ok(Lease {
            state: Mutex::new(Some(state)),
        })
    })()
    .map_err(error)
}
fn existing(directory: &Dir) -> io::Result<Option<File>> {
    match directory.symlink_metadata(JOURNAL) {
        Ok(m) if !m.is_file() || m.len() > LIMIT as u64 => return Err(invalid()),
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    }
    let file = directory.open_with(JOURNAL, &options(false))?.into_std();
    safe_file(&file)?;
    if file.metadata()?.len() > LIMIT as u64 {
        return Err(invalid());
    }
    Ok(Some(file))
}
impl Lease {
    pub fn read(&self) -> anyhow::Result<Option<String>> {
        (|| -> io::Result<_> {
            let guard = self.state.lock().map_err(|_| invalid())?;
            let s = guard.as_ref().ok_or_else(invalid)?;
            s.check()?;
            let Some(mut file) = existing(&s.anchor.directory)? else {
                s.check()?;
                return Ok(None);
            };
            let id = identity(&file)?;
            let mut data = String::new();
            (&mut file)
                .take((LIMIT + 1) as u64)
                .read_to_string(&mut data)?;
            if data.len() > LIMIT {
                return Err(invalid());
            }
            let current = existing(&s.anchor.directory)?.ok_or_else(invalid)?;
            if identity(&current)? != id {
                return Err(invalid());
            }
            s.check()?;
            Ok(Some(data))
        })()
        .map_err(error)
    }
    pub fn write(&self, data: &str) -> anyhow::Result<()> {
        self.write_inner(data, || Ok(()))
    }
    fn write_inner(
        &self,
        data: &str,
        after_rename: impl FnOnce() -> io::Result<()>,
    ) -> anyhow::Result<()> {
        (|| -> io::Result<()> {
            if data.len() > LIMIT
                || !serde_json::from_str::<serde_json::Value>(data).is_ok_and(|v| v.is_object())
            {
                return Err(invalid());
            }
            let mut guard = self.state.lock().map_err(|_| invalid())?;
            let s = guard.as_mut().ok_or_else(invalid)?;
            s.check()?;
            let dir = &s.anchor.directory;
            drop(existing(dir)?);
            let name = format!(".journal-{}.tmp", uuid::Uuid::new_v4());
            let mut opts = options(true);
            opts.create_new(true);
            let mut file = dir.open_with(&name, &opts)?.into_std();
            safe_file(&file)?;
            let temp_id = identity(&file)?;
            let result = (|| -> io::Result<()> {
                file.write_all(data.as_bytes())?;
                file.sync_all()?;
                s.check()?;
                drop(existing(dir)?);
                let check = dir.open_with(&name, &options(false))?.into_std();
                if identity(&check)? != temp_id {
                    return Err(invalid());
                }
                drop(check);
                dir.rename(&name, dir, JOURNAL)?;
                after_rename()?;
                #[cfg(unix)]
                dir.try_clone()?.into_std_file().sync_all()?;
                let published = existing(dir)?.ok_or_else(invalid)?;
                if identity(&published)? != temp_id {
                    return Err(invalid());
                }
                s.check()?;
                Ok(())
            })();
            if result.is_err() {
                // Never unlink a replacement entry while cleaning our temp.
                if let Ok(current) = dir.open_with(&name, &options(false)) {
                    if identity(&current.into_std()).is_ok_and(|id| id == temp_id) {
                        let _ = dir.remove_file(&name);
                    }
                }
                // Rename may already have committed. No stale caller state can
                // overwrite it through this lease; close and reopen to reload.
                s.poisoned = true;
            }
            result
        })()
        .map_err(error)
    }
    pub fn close(&self) -> anyhow::Result<()> {
        self.state.lock().map_err(|_| error(invalid()))?.take();
        Ok(())
    }
}
/// Compatibility helpers also take the actual lease, never bypass it.
pub fn prepare(path: &str) -> anyhow::Result<()> {
    open_directory(path).and_then(|a| a.check()).map_err(error)
}
pub fn read(path: &str) -> anyhow::Result<Option<String>> {
    open(path)?.read()
}
pub fn write(path: &str, data: &str) -> anyhow::Result<()> {
    open(path)?.write(data)
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("legna-journal-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn journal(&self) -> String {
            self.0
                .join(DIRECTORY)
                .join(JOURNAL)
                .to_str()
                .unwrap()
                .into()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn private_atomic_roundtrip_and_prepare_preserves_existing() {
        let f = Fixture::new();
        let p = f.journal();
        prepare(&p).unwrap();
        assert_eq!(read(&p).unwrap(), None);
        write(&p, r#"{"version":1,"secret":"fixture-only"}"#).unwrap();
        prepare(&p).unwrap();
        assert!(read(&p).unwrap().unwrap().contains("fixture-only"));
        write(&p, r#"{"version":2}"#).unwrap();
        assert_eq!(read(&p).unwrap().unwrap(), r#"{"version":2}"#);
        assert_eq!(std::fs::read_dir(f.0.join(DIRECTORY)).unwrap().count(), 2);
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            assert_eq!(
                std::fs::metadata(f.0.join(DIRECTORY)).unwrap().mode() & 0o777,
                0o700
            );
            assert_eq!(std::fs::metadata(&p).unwrap().mode() & 0o777, 0o600);
        }
    }
    #[test]
    fn invalid_budget_data_and_paths_preserve_journal_and_redact_errors() {
        let f = Fixture::new();
        let p = f.journal();
        write(&p, "{\"version\":1}").unwrap();
        for bad in [
            "[]".to_string(),
            "private-token-not-json".into(),
            format!("{{\"x\":\"{}\"}}", "a".repeat(LIMIT)),
        ] {
            let e = write(&p, &bad).unwrap_err().to_string();
            assert!(e.starts_with("source_end_journal_unavailable(kind="));
            assert!(!e.contains(&p));
            assert!(!e.contains("private-token"));
        }
        assert_eq!(read(&p).unwrap().unwrap(), "{\"version\":1}");
        assert!(prepare("source-end-control/journal.json").is_err());
        assert!(prepare(f.0.join("wrong/journal.json").to_str().unwrap()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_hardlinks_and_public_modes_are_rejected_without_touching_target() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let f = Fixture::new();
        let p = f.journal();
        prepare(&p).unwrap();
        let outside = f.0.join("outside");
        std::fs::write(&outside, b"do-not-touch").unwrap();
        symlink(&outside, &p).unwrap();
        assert!(read(&p).is_err());
        assert!(write(&p, "{}").is_err());
        std::fs::remove_file(&p).unwrap();
        std::fs::hard_link(&outside, &p).unwrap();
        assert!(read(&p).is_err());
        assert!(write(&p, "{}").is_err());
        std::fs::remove_file(&p).unwrap();
        write(&p, "{}").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read(&p).is_err());
        assert_eq!(std::fs::read(&outside).unwrap(), b"do-not-touch");
        let other = Fixture::new();
        symlink(f.0.join(DIRECTORY), other.0.join(DIRECTORY)).unwrap();
        assert!(prepare(&other.journal()).is_err());
    }
    #[test]
    fn owned_handle_excludes_second_writer_and_close_is_idempotent() {
        let f = Fixture::new();
        let path = f.journal();
        let lease = open(&path).unwrap();
        assert!(open(&path).is_err());
        assert!(write(&path, "{}").is_err());
        lease.write("{\"value\":1}").unwrap();
        assert_eq!(lease.read().unwrap().as_deref(), Some("{\"value\":1}"));
        lease.close().unwrap();
        lease.close().unwrap();
        assert!(lease.read().is_err());
        let next = open(&path).unwrap();
        assert_eq!(next.read().unwrap().as_deref(), Some("{\"value\":1}"));
    }
    #[cfg(unix)]
    #[test]
    fn replacement_lock_and_directory_invalidate_old_handle_without_following_targets() {
        use std::os::unix::fs::{OpenOptionsExt, symlink};
        let f = Fixture::new();
        let path = f.journal();
        let lease = open(&path).unwrap();
        lease.write("{\"original\":true}").unwrap();
        let lock = f.0.join(DIRECTORY).join(LOCK);
        std::fs::remove_file(&lock).unwrap();
        let replacement = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&lock)
            .unwrap();
        drop(replacement);
        assert!(lease.write("{\"wrong\":true}").is_err());
        assert!(lease.read().is_err());
        lease.close().unwrap();
        let lease = open(&path).unwrap();
        let old = f.0.join("old-private");
        std::fs::rename(f.0.join(DIRECTORY), &old).unwrap();
        symlink(&old, f.0.join(DIRECTORY)).unwrap();
        assert!(lease.write("{\"wrong\":true}").is_err());
        assert!(open(&path).is_err());
        assert_eq!(
            std::fs::read_to_string(old.join(JOURNAL)).unwrap(),
            "{\"original\":true}"
        );
    }
    #[test]
    fn unknown_commit_poisons_native_handle_and_reopen_reads_actual_committed_value() {
        let f = Fixture::new();
        let path = f.journal();
        let lease = open(&path).unwrap();
        lease.write("{\"old\":true}").unwrap();
        assert!(
            lease
                .write_inner("{\"intent\":true}", || Err(io::Error::other(
                    "injected sync failure"
                )))
                .is_err()
        );
        assert!(lease.write("{\"old\":true}").is_err());
        assert!(lease.read().is_err());
        lease.close().unwrap();
        let reopened = open(&path).unwrap();
        assert_eq!(
            reopened.read().unwrap().as_deref(),
            Some("{\"intent\":true}")
        );
    }
    #[cfg(unix)]
    #[test]
    fn symlink_and_hardlinked_lease_entries_are_never_locked() {
        use std::os::unix::fs::{OpenOptionsExt, symlink};
        let f = Fixture::new();
        let p = f.journal();
        prepare(&p).unwrap();
        let outside = f.0.join("outside-lock");
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&outside)
            .unwrap();
        drop(file);
        let lock = f.0.join(DIRECTORY).join(LOCK);
        symlink(&outside, &lock).unwrap();
        assert!(open(&p).is_err());
        std::fs::remove_file(&lock).unwrap();
        std::fs::hard_link(&outside, &lock).unwrap();
        assert!(open(&p).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn lock_replaced_between_open_and_lock_is_rejected() {
        use std::os::unix::fs::{OpenOptionsExt, symlink};
        let f = Fixture::new();
        let p = f.journal();
        prepare(&p).unwrap();
        let outside = f.0.join("unrelated-lock");
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&outside)
            .unwrap();
        let lock = f.0.join(DIRECTORY).join(LOCK);
        assert!(
            open_inner(&p, || {
                std::fs::remove_file(&lock)?;
                symlink(&outside, &lock)
            })
            .is_err()
        );
        // The original no-follow opened inode, not the swapped target, was locked.
        crate::file_lock::try_exclusive_strict(&file).unwrap();
        assert_eq!(file.metadata().unwrap().len(), 0);
    }
    #[test]
    #[ignore = "helper launched only by the bounded parent test"]
    fn journal_lock_child() {
        let path = std::env::var("LEGNA_SOURCE_END_LOCK_PATH").unwrap();
        let busy = std::env::var("LEGNA_SOURCE_END_LOCK_BUSY").unwrap() == "1";
        assert_eq!(open(&path).is_err(), busy);
    }
    #[test]
    fn opaque_lease_excludes_a_second_process_until_actual_close() {
        let f = Fixture::new();
        let path = f.journal();
        let lease = open(&path).unwrap();
        let child = |busy: bool| {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "source_end_journal::tests::journal_lock_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env("LEGNA_SOURCE_END_LOCK_PATH", &path)
                .env("LEGNA_SOURCE_END_LOCK_BUSY", if busy { "1" } else { "0" })
                .output()
                .unwrap()
        };
        let first = child(true);
        assert!(
            first.status.success(),
            "{}",
            String::from_utf8_lossy(&first.stderr)
        );
        lease.close().unwrap();
        let second = child(false);
        assert!(
            second.status.success(),
            "{}",
            String::from_utf8_lossy(&second.stderr)
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "helper launched inside a bounded sandbox-exec child"]
    fn apple_sandbox_journal_child() {
        let root = PathBuf::from(std::env::var_os("LEGNA_SANDBOX_JOURNAL_ROOT").unwrap());
        assert!(
            File::open("/private").is_err(),
            "The sandbox must deny opening the ancestor directory"
        );
        // The app-owned directory itself remains authorized. Opening it must
        // not require separately opening its unauthorized ancestors for reading.
        assert!(File::open(&root).unwrap().metadata().unwrap().is_dir());
        let path = root.join(DIRECTORY).join(JOURNAL);
        let lease =
            open(path.to_str().unwrap()).expect("Authorized journal should open in sandbox");
        lease.write("{\"fixture\":true}").unwrap();
        assert_eq!(lease.read().unwrap().as_deref(), Some("{\"fixture\":true}"));
        assert!(open(path.to_str().unwrap()).is_err());
        lease.close().unwrap();
        assert_eq!(
            read(path.to_str().unwrap()).unwrap().as_deref(),
            Some("{\"fixture\":true}")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn apple_sandbox_journal_does_not_open_unauthorized_ancestors() {
        let f = Fixture::new();
        let output = std::process::Command::new("/usr/bin/sandbox-exec")
            .args([
                "-p",
                "(version 1)(allow default)(deny file-read-data (literal \"/private\"))",
            ])
            .arg(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "source_end_journal::tests::apple_sandbox_journal_child",
                "--ignored",
                "--nocapture",
            ])
            .env("LEGNA_SANDBOX_JOURNAL_ROOT", &f.0)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "sandbox journal child failed:\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            std::fs::read_to_string(f.journal()).unwrap(),
            "{\"fixture\":true}"
        );
    }

    #[test]
    fn redacted_diagnostics_keep_error_kind_but_not_private_context() {
        let message = error(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "private-path secret-token",
        ))
        .to_string();
        assert_eq!(
            message,
            "source_end_journal_unavailable(kind=PermissionDenied, errno=none)"
        );
        #[cfg(unix)]
        assert_eq!(
            error(io::Error::from_raw_os_error(libc::EACCES)).to_string(),
            format!(
                "source_end_journal_unavailable(kind=PermissionDenied, errno={})",
                libc::EACCES
            )
        );
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn apple_search_only_ancestor_allows_journal_in_authorized_root() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let parent = f.0.join("search-only");
        let root = parent.join("owned");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o111)).unwrap();
        let ancestor_open = File::open(&parent);
        let result = (|| -> anyhow::Result<()> {
            let path = root.join(DIRECTORY).join(JOURNAL);
            let lease = open(path.to_str().unwrap())?;
            lease.write("{\"owned\":true}")?;
            assert_eq!(lease.read()?.as_deref(), Some("{\"owned\":true}"));
            lease.close()
        })();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
        if unsafe { libc::geteuid() } != 0 {
            assert!(ancestor_open.is_err());
        }
        result.unwrap();
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn apple_root_replacement_and_aliases_invalidate_journal_without_mutating_old_data() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let root = f.0.join("owned");
        std::fs::create_dir(&root).unwrap();
        let path = root.join(DIRECTORY).join(JOURNAL);
        let lease = open(path.to_str().unwrap()).unwrap();
        lease.write("{\"original\":true}").unwrap();
        let old = f.0.join("old-owned");
        std::fs::rename(&root, &old).unwrap();
        std::fs::create_dir(&root).unwrap();
        write(path.to_str().unwrap(), "{\"replacement\":true}").unwrap();
        assert!(lease.read().is_err());
        assert!(lease.write("{}").is_err());
        assert_eq!(
            std::fs::read_to_string(old.join(DIRECTORY).join(JOURNAL)).unwrap(),
            "{\"original\":true}"
        );
        assert_eq!(
            read(path.to_str().unwrap()).unwrap().as_deref(),
            Some("{\"replacement\":true}")
        );
        symlink(&old, f.0.join("root-link")).unwrap();
        assert!(
            open(
                f.0.join("root-link")
                    .join(DIRECTORY)
                    .join(JOURNAL)
                    .to_str()
                    .unwrap()
            )
            .is_err()
        );
        symlink(&f.0, f.0.join("ancestor-link")).unwrap();
        assert!(
            open(
                f.0.join("ancestor-link/owned")
                    .join(DIRECTORY)
                    .join(JOURNAL)
                    .to_str()
                    .unwrap()
            )
            .is_err()
        );
        let noncanonical = format!("{}/./owned/{DIRECTORY}/{JOURNAL}", f.0.display());
        assert!(open(&noncanonical).is_err());
    }
}
