//! Borrowed-file, nonblocking exclusive locks with identical ownership rules.
//! Rust 1.97's std Unix lock implementation omits Android from its supported
//! cfg list. Use Android's real flock syscall, never interpret Unsupported as success.
//!
//! Android FUSE-mounted shared storage (Android 11+) may lack flock AND OFD
//! support. The fallback chain is: flock → OFD → POSIX F_SETLK → advisory noop.
//! Each transition only fires on ENOSYS/EOPNOTSUPP, never on contention or I/O.
//! Durable ownership uses the separate strict API: only std/flock/OFD locks,
//! never process-scoped POSIX locks or an advisory no-op.
use std::{
    fs::{File, TryLockError},
    io,
};

/// The concrete lock namespace must accompany every explicit unlock. Do not
/// infer it from the fd number (reused) or use an unrelated no-op unlock.
#[derive(Clone, Copy, Debug)]
pub(crate) enum LockFlavor {
    #[cfg(not(target_os = "android"))]
    Standard,
    #[cfg(target_os = "android")]
    Flock,
    #[cfg(target_os = "android")]
    OpenDescription,
    #[cfg(target_os = "android")]
    Posix,
    #[cfg(target_os = "android")]
    Advisory,
}

pub(crate) fn try_exclusive(file: &File) -> Result<(), TryLockError> {
    acquire(file).map(|_| ())
}
/// Descriptor-lifetime exclusion for durable caches and their private registries.
/// Unsupported filesystems fail closed; callers must not fall back to `acquire`.
pub(crate) fn try_exclusive_strict(file: &File) -> Result<(), TryLockError> {
    acquire_strict(file).map(|_| ())
}

/// Read-only recovery candidates need a description-scoped shared lock; OFD
/// write locks are invalid on read-only provider descriptors. No weak fallback.
pub(crate) fn try_shared_strict(file: &File) -> Result<(), TryLockError> {
    #[cfg(target_os = "android")]
    {
        acquire_description_lock(
            || native_try_shared(file),
            || ofd(file, libc::F_RDLCK as libc::c_short),
        )
        .map(|_| ())
    }
    #[cfg(not(target_os = "android"))]
    {
        file.try_lock_shared()
    }
}

pub(crate) fn acquire_strict(file: &File) -> Result<LockFlavor, TryLockError> {
    #[cfg(target_os = "android")]
    {
        acquire_description_lock(
            || native_try_exclusive(file),
            || ofd(file, libc::F_WRLCK as libc::c_short),
        )
        .map(|flavor| match flavor {
            DescriptionLock::Flock => LockFlavor::Flock,
            DescriptionLock::OpenDescription => LockFlavor::OpenDescription,
        })
    }
    #[cfg(not(target_os = "android"))]
    {
        file.try_lock().map(|_| LockFlavor::Standard)
    }
}

#[cfg(any(target_os = "android", all(test, unix)))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DescriptionLock {
    Flock,
    OpenDescription,
}

/// The injected operations are also used by the real Android branch. There is
/// deliberately no callback for POSIX or no-op fallback.
#[cfg(any(target_os = "android", all(test, unix)))]
fn acquire_description_lock(
    flock: impl FnOnce() -> Result<(), TryLockError>,
    ofd: impl FnOnce() -> io::Result<()>,
) -> Result<DescriptionLock, TryLockError> {
    match flock() {
        Ok(()) => Ok(DescriptionLock::Flock),
        Err(TryLockError::Error(error)) if permits_fallback(&error) => ofd()
            .map(|()| DescriptionLock::OpenDescription)
            .map_err(lock_error),
        Err(error) => Err(error),
    }
}

#[cfg(any(target_os = "android", all(test, unix)))]
fn unlock_description_lock(
    flavor: DescriptionLock,
    flock: impl FnOnce() -> io::Result<()>,
    ofd: impl FnOnce() -> io::Result<()>,
) -> io::Result<()> {
    match flavor {
        DescriptionLock::Flock => flock(),
        DescriptionLock::OpenDescription => ofd(),
    }
}

/// Compatibility policy for non-durable operations; intentionally unchanged.
pub(crate) fn acquire(file: &File) -> Result<LockFlavor, TryLockError> {
    #[cfg(target_os = "android")]
    {
        match native_try_exclusive(file) {
            Ok(()) => Ok(LockFlavor::Flock),
            Err(TryLockError::Error(error)) if permits_fallback(&error) => {
                match ofd(file, libc::F_WRLCK as libc::c_short) {
                    Ok(()) => Ok(LockFlavor::OpenDescription),
                    Err(ofd_err) if permits_fallback(&ofd_err) => {
                        match posix_setlk(file, libc::F_WRLCK as libc::c_short) {
                            Ok(()) => {
                                tracing::debug!(
                                    "file lock: flock+OFD unavailable, using POSIX F_SETLK"
                                );
                                Ok(LockFlavor::Posix)
                            }
                            Err(posix_err) if permits_fallback(&posix_err) => {
                                tracing::warn!(
                                    "file lock: flock+OFD+POSIX all unavailable on this filesystem; proceeding without lock"
                                );
                                Ok(LockFlavor::Advisory)
                            }
                            Err(posix_err) => Err(lock_error(posix_err)),
                        }
                    }
                    Err(ofd_err) => Err(lock_error(ofd_err)),
                }
            }
            Err(error) => Err(error),
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        file.try_lock().map(|_| LockFlavor::Standard)
    }
}
pub(crate) fn unlock(file: &File, flavor: LockFlavor) -> io::Result<()> {
    match flavor {
        #[cfg(not(target_os = "android"))]
        LockFlavor::Standard => file.unlock(),
        #[cfg(target_os = "android")]
        LockFlavor::Flock => unlock_description_lock(
            DescriptionLock::Flock,
            || native_unlock(file),
            || ofd(file, libc::F_UNLCK as libc::c_short),
        ),
        #[cfg(target_os = "android")]
        LockFlavor::OpenDescription => unlock_description_lock(
            DescriptionLock::OpenDescription,
            || native_unlock(file),
            || ofd(file, libc::F_UNLCK as libc::c_short),
        ),
        #[cfg(target_os = "android")]
        LockFlavor::Posix => posix_setlk(file, libc::F_UNLCK as libc::c_short),
        #[cfg(target_os = "android")]
        LockFlavor::Advisory => Ok(()),
    }
}
#[cfg(any(target_os = "android", test))]
fn permits_fallback(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOSYS | libc::EOPNOTSUPP))
}
#[cfg(any(target_os = "android", all(test, unix)))]
fn lock_error(error: io::Error) -> TryLockError {
    if error.kind() == io::ErrorKind::WouldBlock {
        TryLockError::WouldBlock
    } else {
        TryLockError::Error(error)
    }
}
#[cfg(target_os = "android")]
fn ofd(file: &File, operation: libc::c_short) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let mut lock: libc::flock = unsafe { std::mem::zeroed() };
    lock.l_type = operation;
    lock.l_whence = libc::SEEK_SET as libc::c_short;
    lock.l_start = 0;
    lock.l_len = 0;
    lock.l_pid = 0;
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_OFD_SETLK, &lock) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(target_os = "android")]
fn posix_setlk(file: &File, operation: libc::c_short) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let mut lock: libc::flock = unsafe { std::mem::zeroed() };
    lock.l_type = operation;
    lock.l_whence = libc::SEEK_SET as libc::c_short;
    lock.l_start = 0;
    lock.l_len = 0;
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &lock) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(target_os = "android")]
fn native_try_shared(file: &File) -> Result<(), TryLockError> {
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0 {
        Ok(())
    } else {
        Err(lock_error(io::Error::last_os_error()))
    }
}

#[cfg(any(target_os = "android", all(test, unix)))]
fn native_try_exclusive(file: &File) -> Result<(), TryLockError> {
    use std::os::fd::AsRawFd;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock {
        Err(TryLockError::WouldBlock)
    } else {
        Err(TryLockError::Error(error))
    }
}
#[cfg(any(target_os = "android", all(test, unix)))]
fn native_unlock(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    #[test]
    fn native_flock_conflict_unlock_and_descriptor_lifetime_are_real() {
        let path = std::env::temp_dir().join(format!("legna-flock-{}", uuid::Uuid::new_v4()));
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let second = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        native_try_exclusive(&file).unwrap();
        assert!(matches!(
            native_try_exclusive(&second),
            Err(TryLockError::WouldBlock)
        ));
        drop(file.try_clone().unwrap());
        assert!(matches!(
            native_try_exclusive(&second),
            Err(TryLockError::WouldBlock)
        ));
        native_unlock(&file).unwrap();
        native_try_exclusive(&second).unwrap();
        assert!(matches!(
            native_try_exclusive(&file),
            Err(TryLockError::WouldBlock)
        ));
        drop(second);
        native_try_exclusive(&file).unwrap();
        native_unlock(&file).unwrap();
        drop(file);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn fallback_requires_explicit_missing_flock_not_contention_or_generic_unsupported() {
        assert!(permits_fallback(&io::Error::from_raw_os_error(
            libc::ENOSYS
        )));
        assert!(permits_fallback(&io::Error::from_raw_os_error(
            libc::EOPNOTSUPP
        )));
        for errno in [
            libc::EAGAIN,
            libc::EACCES,
            libc::EBADF,
            libc::EINVAL,
            libc::EIO,
        ] {
            assert!(!permits_fallback(&io::Error::from_raw_os_error(errno)));
        }
        assert!(!permits_fallback(&io::Error::from(
            io::ErrorKind::Unsupported
        )));
    }
    #[test]
    fn platform_wrapper_preserves_existing_non_android_exclusion() {
        let path =
            std::env::temp_dir().join(format!("legna-lock-wrapper-{}", uuid::Uuid::new_v4()));
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let second = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let flavor = acquire(&file).unwrap();
        assert!(matches!(
            try_exclusive(&second),
            Err(TryLockError::WouldBlock)
        ));
        unlock(&file, flavor).unwrap();
        try_exclusive(&second).unwrap();
        drop(second);
        drop(file);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn strict_flock_success_never_calls_fallback() {
        assert_eq!(
            acquire_description_lock(|| Ok(()), || panic!("unexpected OFD")).unwrap(),
            DescriptionLock::Flock
        );
    }

    #[test]
    fn strict_missing_flock_uses_only_ofd_and_returns_its_flavor() {
        for errno in [libc::ENOSYS, libc::EOPNOTSUPP] {
            assert_eq!(
                acquire_description_lock(
                    || Err(TryLockError::Error(io::Error::from_raw_os_error(errno))),
                    || Ok(()),
                )
                .unwrap(),
                DescriptionLock::OpenDescription
            );
        }
    }

    #[test]
    fn strict_contention_and_io_errors_never_call_fallback() {
        assert!(matches!(
            acquire_description_lock(
                || Err(TryLockError::WouldBlock),
                || panic!("contention bypass")
            ),
            Err(TryLockError::WouldBlock)
        ));
        for errno in [
            libc::EAGAIN,
            libc::EACCES,
            libc::EBADF,
            libc::EINVAL,
            libc::EIO,
        ] {
            match acquire_description_lock(
                || Err(TryLockError::Error(io::Error::from_raw_os_error(errno))),
                || panic!("I/O error bypass"),
            ) {
                Err(TryLockError::Error(error)) => assert_eq!(error.raw_os_error(), Some(errno)),
                other => panic!("wrong result: {other:?}"),
            }
        }
        assert!(matches!(
            acquire_description_lock(
                || Err(TryLockError::Error(io::ErrorKind::Unsupported.into())),
                || panic!("generic unsupported bypass")
            ),
            Err(TryLockError::Error(_))
        ));
    }

    #[test]
    fn strict_both_unsupported_fail_with_ofd_error_not_success() {
        for first in [libc::ENOSYS, libc::EOPNOTSUPP] {
            for second in [libc::ENOSYS, libc::EOPNOTSUPP] {
                match acquire_description_lock(
                    || Err(TryLockError::Error(io::Error::from_raw_os_error(first))),
                    || Err(io::Error::from_raw_os_error(second)),
                ) {
                    Err(TryLockError::Error(error)) => {
                        assert_eq!(error.raw_os_error(), Some(second))
                    }
                    other => panic!("unsupported lock accepted: {other:?}"),
                }
            }
        }
    }

    #[test]
    fn strict_ofd_contention_and_io_are_preserved() {
        for errno in [
            libc::EAGAIN,
            libc::EACCES,
            libc::EBADF,
            libc::EINVAL,
            libc::EIO,
        ] {
            let result = acquire_description_lock(
                || {
                    Err(TryLockError::Error(io::Error::from_raw_os_error(
                        libc::ENOSYS,
                    )))
                },
                || Err(io::Error::from_raw_os_error(errno)),
            );
            if io::Error::from_raw_os_error(errno).kind() == io::ErrorKind::WouldBlock {
                assert!(matches!(result, Err(TryLockError::WouldBlock)));
            } else {
                match result {
                    Err(TryLockError::Error(error)) => {
                        assert_eq!(error.raw_os_error(), Some(errno))
                    }
                    other => panic!("OFD error bypass: {other:?}"),
                }
            }
        }
    }

    #[test]
    fn strict_unlock_dispatches_only_the_acquired_namespace_and_preserves_failure() {
        unlock_description_lock(
            DescriptionLock::Flock,
            || Ok(()),
            || panic!("wrong namespace"),
        )
        .unwrap();
        unlock_description_lock(
            DescriptionLock::OpenDescription,
            || panic!("wrong namespace"),
            || Ok(()),
        )
        .unwrap();
        let error = unlock_description_lock(
            DescriptionLock::Flock,
            || Err(io::Error::from_raw_os_error(libc::EIO)),
            || panic!("unlock fallback"),
        )
        .unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EIO));
        let error = unlock_description_lock(
            DescriptionLock::OpenDescription,
            || panic!("unlock fallback"),
            || Err(io::Error::from_raw_os_error(libc::EBADF)),
        )
        .unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EBADF));
    }

    #[test]
    fn strict_platform_lock_survives_independent_witness_close_and_unlocks() {
        let path = std::env::temp_dir().join(format!("legna-strict-lock-{}", uuid::Uuid::new_v4()));
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let contender = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let flavor = acquire_strict(&file).unwrap();
        assert!(matches!(
            try_exclusive_strict(&contender),
            Err(TryLockError::WouldBlock)
        ));
        drop(OpenOptions::new().read(true).open(&path).unwrap());
        drop(file.try_clone().unwrap());
        assert!(matches!(
            try_exclusive_strict(&contender),
            Err(TryLockError::WouldBlock)
        ));
        unlock(&file, flavor).unwrap();
        let contender_flavor = acquire_strict(&contender).unwrap();
        assert!(matches!(
            try_exclusive_strict(&file),
            Err(TryLockError::WouldBlock)
        ));
        unlock(&contender, contender_flavor).unwrap();
        try_exclusive_strict(&file).unwrap();
        drop(file);
        try_exclusive_strict(&contender).unwrap();
        drop(contender);
        std::fs::remove_file(path).unwrap();
    }
}
