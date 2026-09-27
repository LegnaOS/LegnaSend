//! Background registry maintenance has no Apple document-coordination lease.
//! A persisted path is not an authorization to reopen a Files provider root.
use cap_fs_ext::DirExt;
use std::path::Path;

pub(crate) fn requires_coordinated_access(parent: &Path) -> bool {
    #[cfg(target_os = "ios")]
    {
        !std::env::var_os("HOME").is_some_and(|home| sandbox_parent(parent, Path::new(&home)))
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = parent;
        false
    }
}

/// An operation-local directory handle. The native caller must keep its Apple
/// security scope and coordinated accessor alive until this operation returns.
/// Never stored globally, and never makes the unscoped maintenance path trusted.
pub(crate) struct CoordinatedRoot {
    path: std::path::PathBuf,
    dir: cap_std::fs::Dir,
}
impl CoordinatedRoot {
    pub(crate) fn open(path: &Path) -> std::io::Result<Self> {
        use std::path::Component;
        if !path.is_absolute()
            || path.parent().is_none()
            || path
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        {
            return Err(std::io::Error::other("Invalid coordinated receive root"));
        }
        #[cfg(target_vendor = "apple")]
        let dir = {
            use std::os::fd::AsRawFd;
            use std::os::unix::ffi::OsStrExt;
            use std::os::unix::fs::OpenOptionsExt;
            // A scoped bookmark authorizes this directory and its descendants,
            // not separately opening every parent from '/'. Open only the final
            // root; the kernel rejects symlinks anywhere in this one lookup.
            // Do not retry with weaker O_NOFOLLOW or ambient directory traversal.
            let file = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW_ANY)
                .open(path)?;
            // File::metadata is fstat: verify the pinned object, not the path.
            if !file.metadata()?.is_dir() {
                return Err(std::io::Error::other("Invalid coordinated receive root"));
            }
            let mut actual = [0u8; libc::PATH_MAX as usize];
            // SAFETY: file owns a live descriptor and actual is a writable
            // PATH_MAX buffer as required by Darwin's public F_GETPATH API.
            if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, actual.as_mut_ptr()) } == -1
            {
                return Err(std::io::Error::last_os_error());
            }
            let end = actual
                .iter()
                .position(|byte| *byte == 0)
                .ok_or_else(|| std::io::Error::other("Invalid coordinated receive root path"))?;
            if std::ffi::OsStr::from_bytes(&actual[..end]) != path.as_os_str() {
                return Err(std::io::Error::other("Coordinated receive root changed"));
            }
            cap_std::fs::Dir::from_std_file(file)
        };
        #[cfg(not(target_vendor = "apple"))]
        let dir = {
            if std::fs::canonicalize(path)? != path {
                return Err(std::io::Error::other("Invalid coordinated receive root"));
            }
            // Other platforms retain component-by-component capability pinning.
            let mut anchor = std::path::PathBuf::new();
            let mut parts = Vec::new();
            for part in path.components() {
                match part {
                    Component::Prefix(_) | Component::RootDir => anchor.push(part.as_os_str()),
                    Component::Normal(name) => parts.push(name),
                    _ => return Err(std::io::Error::other("Invalid coordinated receive root")),
                }
            }
            let mut dir = cap_std::fs::Dir::open_ambient_dir(anchor, cap_std::ambient_authority())?;
            for name in parts {
                dir = dir.open_dir_nofollow(name)?;
            }
            dir
        };
        Ok(Self {
            path: path.into(),
            dir,
        })
    }
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
    pub(crate) fn contains(&self, parent: &Path) -> bool {
        use std::path::Component;
        parent.strip_prefix(&self.path).is_ok_and(|relative| {
            relative
                .components()
                .all(|c| matches!(c, Component::Normal(_)))
        })
    }
    pub(crate) fn open_parent(&self, parent: &Path) -> std::io::Result<cap_std::fs::Dir> {
        if !self.contains(parent) {
            return Err(std::io::Error::other(
                "Receive parent is outside coordinated root",
            ));
        }
        let mut dir = self.dir.try_clone()?;
        for name in parent.strip_prefix(&self.path).unwrap().components() {
            dir = dir.open_dir_nofollow(name.as_os_str())?;
        }
        Ok(dir)
    }
}

#[cfg(any(target_os = "ios", test))]
fn sandbox_parent(parent: &Path, home: &Path) -> bool {
    use std::path::Component;
    if !home.is_absolute()
        || home.parent().is_none()
        || !parent.is_absolute()
        || parent
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return false;
    }
    let Ok(home_real) = std::fs::canonicalize(home) else {
        return false;
    };
    if !parent.starts_with(home) && !parent.starts_with(&home_real) {
        return false;
    }
    std::fs::canonicalize(parent).is_ok_and(|path| path.starts_with(home_real))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sandbox_maintenance_does_not_authorize_external_or_traversal_paths() {
        let base = std::env::temp_dir().join(format!("ls-scope-policy-{}", uuid::Uuid::new_v4()));
        let home = base.join("app");
        let external = base.join("app-other");
        std::fs::create_dir_all(home.join("Documents/Downloads")).unwrap();
        std::fs::create_dir_all(&external).unwrap();
        assert!(sandbox_parent(&home.join("Documents/Downloads"), &home));
        assert!(!sandbox_parent(&external, &home));
        assert!(!sandbox_parent(&home.join("../app-other"), &home));
        assert!(!sandbox_parent(&home, Path::new("/")));
        assert!(!sandbox_parent(&home.join("missing"), &home));
        std::fs::remove_dir_all(base).unwrap();
    }
    #[cfg(target_vendor = "apple")]
    #[test]
    fn apple_coordinated_root_opens_only_the_authorized_directory() {
        use std::os::unix::fs::PermissionsExt;
        let base = std::env::temp_dir().join(format!("ls-scoped-direct-{}", uuid::Uuid::new_v4()));
        let parent = base.join("search-only");
        let root = parent.join("granted");
        std::fs::create_dir_all(root.join("child")).unwrap();
        let root = std::fs::canonicalize(root).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o111)).unwrap();
        let parent_open = std::fs::File::open(&parent);
        let opened = CoordinatedRoot::open(&root);
        // Restore cleanup permission before assertions, including failed opens.
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
        if unsafe { libc::geteuid() } != 0 {
            assert!(parent_open.is_err(), "The ungranted parent is search-only");
        }
        let opened = opened.expect("Direct authorized root does not need a readable parent");
        assert_eq!(opened.path(), root);
        assert!(opened.open_parent(&root.join("child")).is_ok());
        assert!(opened.open_parent(root.parent().unwrap()).is_err());
        drop(opened);
        std::fs::remove_dir_all(base).unwrap();
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn apple_coordinated_root_rejects_intermediate_and_final_symlinks() {
        let base =
            std::env::temp_dir().join(format!("ls-scoped-nofollow-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(base.join("real/root")).unwrap();
        let base = std::fs::canonicalize(base).unwrap();
        let root = base.join("real/root");
        std::os::unix::fs::symlink(base.join("real"), base.join("middle-link")).unwrap();
        std::os::unix::fs::symlink(&root, base.join("final-link")).unwrap();
        assert!(CoordinatedRoot::open(&root).is_ok());
        assert!(CoordinatedRoot::open(&base.join("middle-link/root")).is_err());
        assert!(CoordinatedRoot::open(&base.join("final-link")).is_err());
        std::fs::write(base.join("regular-file"), b"not a directory").unwrap();
        assert!(CoordinatedRoot::open(&base.join("regular-file")).is_err());
        assert!(CoordinatedRoot::open(&root.join("..")).is_err());
        assert!(CoordinatedRoot::open(Path::new("/")).is_err());
        // Kernel normalization must not silently change the approved root string.
        let noncanonical =
            std::path::PathBuf::from(format!("{}/./root", base.join("real").display()));
        assert!(CoordinatedRoot::open(&noncanonical).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_sandbox_named_symlink_does_not_grant_provider_access() {
        let base = std::env::temp_dir().join(format!("ls-scope-link-{}", uuid::Uuid::new_v4()));
        let home = base.join("app");
        let external = base.join("provider");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&external).unwrap();
        std::os::unix::fs::symlink(&external, home.join("escape")).unwrap();
        assert!(!sandbox_parent(&home.join("escape"), &home));
        std::fs::remove_dir_all(base).unwrap();
    }
}
