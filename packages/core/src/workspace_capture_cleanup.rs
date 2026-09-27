//! Conservative cleanup of private, non-resumable workspace exports.
//! All file operations are relative to pinned directory handles. No recursive
//! deletion and no ambient traversal after a stage has been opened.
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use serde::{Deserialize, Serialize};
use std::{
    io::{self, Read},
    path::{Component, Path, PathBuf},
};

const FORMAT: &str = "legnasend.workspace-capture.v1";
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Report {
    examined: u32,
    active: u32,
    retained: u32,
    failed: u32,
    removed_stages: u32,
    removed_files: u32,
    unlinked_bytes: u64,
    budget_reached: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    format: String,
    id: String,
    count: u16,
}

/// Host-only cleanup; the caller must hold its process lease and exclude live
/// stages. The supplied root must already be canonical and absolute.
pub async fn cleanup_workspace_capture(root: String, id: String) -> anyhow::Result<String> {
    let report = tokio::task::spawn_blocking(move || cleanup(Path::new(&root), &id, || ())).await?;
    Ok(serde_json::to_string(&report)?)
}
fn valid_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|value| {
        value.to_string() == id
            && value.get_version_num() == 4
            && value.get_variant() == uuid::Variant::RFC4122
    })
}
fn open_root(path: &Path) -> io::Result<Dir> {
    if !path.is_absolute() {
        return Err(io::Error::other("Capture root is not absolute"));
    }
    let mut anchor = PathBuf::new();
    let mut children = Vec::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir => anchor.push(component.as_os_str()),
            Component::Normal(name) => children.push(name),
            _ => return Err(io::Error::other("Invalid capture root")),
        }
    }
    let mut directory = Dir::open_ambient_dir(anchor, ambient_authority())?;
    for component in children {
        directory = directory.open_dir_nofollow(component)?;
    }
    Ok(directory)
}
fn same_directory(first: &Dir, second: &Dir) -> io::Result<bool> {
    Ok(
        same_file::Handle::from_file(first.try_clone()?.into_std_file())?
            == same_file::Handle::from_file(second.try_clone()?.into_std_file())?,
    )
}
fn cleanup(root: &Path, id: &str, after_preflight: impl FnOnce()) -> Report {
    let mut report = Report {
        examined: 1,
        ..Default::default()
    };
    if !valid_id(id) {
        report.retained = 1;
        return report;
    }
    let result = (|| -> io::Result<bool> {
        let parent = open_root(root)?;
        // Checking and opening with no-follow are both necessary: the latter
        // protects against a directory-to-symlink replacement between calls.
        if !parent.symlink_metadata(id)?.is_dir() {
            return Ok(false);
        }
        let stage = parent.open_dir_nofollow(id)?;
        if !stage.symlink_metadata("owner.json")?.is_file() {
            return Ok(false);
        }
        let mut options = OpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        let owner = stage.open_with("owner.json", &options)?;
        if !owner.metadata()?.is_file() {
            return Ok(false);
        }
        let mut encoded = Vec::new();
        owner.take(1025).read_to_end(&mut encoded)?;
        if encoded.len() > 1024 {
            return Ok(false);
        }
        let Ok(marker) = serde_json::from_slice::<Owner>(&encoded) else {
            return Ok(false);
        };
        if marker.format != FORMAT || marker.id != id || !(1..=128).contains(&marker.count) {
            return Ok(false);
        }
        let mut entries = Vec::new();
        for entry in stage.entries()? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                return Ok(false);
            };
            if entries.len() >= 129 || !stage.symlink_metadata(name)?.is_file() {
                return Ok(false);
            }
            if name != "owner.json"
                && !(0..marker.count).any(|index| name == format!("source-{index}"))
            {
                return Ok(false);
            }
            entries.push(name.to_owned());
        }
        // Do not remove payloads if the owner vanished during the preflight.
        if !entries.iter().any(|name| name == "owner.json") {
            return Ok(false);
        }
        after_preflight();
        for name in entries {
            if name == "owner.json" {
                continue;
            }
            let metadata = stage.symlink_metadata(&name)?;
            if !metadata.is_file() {
                return Ok(false);
            }
            stage.remove_file(&name)?;
            report.removed_files += 1;
            report.unlinked_bytes = report.unlinked_bytes.saturating_add(metadata.len());
        }
        // Relative unlink never follows a late symlink or an ancestor swap.
        // A late unknown entry makes the final nonrecursive rmdir fail intact.
        if !stage.symlink_metadata("owner.json")?.is_file() {
            return Ok(false);
        }
        stage.remove_file("owner.json")?;
        let current = parent.open_dir_nofollow(id)?;
        if !same_directory(&stage, &current)? {
            return Ok(false);
        }
        parent.remove_dir(id)?;
        report.removed_stages = 1;
        Ok(true)
    })();
    match result {
        Ok(true) => {}
        Ok(false) => report.retained = 1,
        Err(_) => report.failed = 1,
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    struct Fixture {
        path: PathBuf,
        id: String,
    }
    impl Fixture {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("capture-cleanup-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            let path = path.canonicalize().unwrap();
            let id = uuid::Uuid::new_v4().to_string();
            fs::create_dir(path.join(&id)).unwrap();
            fs::write(
                path.join(&id).join("owner.json"),
                serde_json::json!({"format":FORMAT,"id":id,"count":2}).to_string(),
            )
            .unwrap();
            fs::write(path.join(&id).join("source-0"), "payload").unwrap();
            Self { path, id }
        }
        fn stage(&self) -> PathBuf {
            self.path.join(&self.id)
        }
        fn run(&self) -> Report {
            cleanup(&self.path, &self.id, || ())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
    #[tokio::test]
    async fn valid_stage_reports_original_payload_bytes_and_removes_stage() {
        let fixture = Fixture::new();
        let report: serde_json::Value = serde_json::from_str(
            &cleanup_workspace_capture(
                fixture.path.to_string_lossy().into_owned(),
                fixture.id.clone(),
            )
            .await
            .unwrap(),
        )
        .unwrap();
        assert_eq!(report["removedStages"], 1);
        assert_eq!(report["removedFiles"], 1);
        assert_eq!(report["unlinkedBytes"], 7);
        assert_eq!(report["active"], 0);
        assert_eq!(report["budgetReached"], false);
        assert!(!fixture.stage().exists());
    }
    #[test]
    fn unknown_entries_and_invalid_markers_retain_all_payloads() {
        for kind in [
            "foreign",
            "directory",
            "large",
            "malformed",
            "extra",
            "wrong-id",
            "too-many",
        ] {
            let f = Fixture::new();
            match kind {
                "foreign" => fs::write(f.stage().join("unknown"), "keep").unwrap(),
                "directory" => fs::create_dir(f.stage().join("source-1")).unwrap(),
                "large" => fs::write(f.stage().join("owner.json"), vec![b' '; 1025]).unwrap(),
                "malformed" => fs::write(f.stage().join("owner.json"), "{").unwrap(),
                "extra" => fs::write(
                    f.stage().join("owner.json"),
                    serde_json::json!({"format":FORMAT,"id":f.id,"count":2,"extra":true})
                        .to_string(),
                )
                .unwrap(),
                "wrong-id" => fs::write(
                    f.stage().join("owner.json"),
                    serde_json::json!({"format":FORMAT,"id":"other","count":2}).to_string(),
                )
                .unwrap(),
                _ => fs::write(
                    f.stage().join("owner.json"),
                    serde_json::json!({"format":FORMAT,"id":f.id,"count":129}).to_string(),
                )
                .unwrap(),
            }
            let result = f.run();
            assert_eq!(result.retained, 1, "{kind}");
            assert_eq!(result.removed_files, 0);
            assert_eq!(fs::read(f.stage().join("source-0")).unwrap(), b"payload");
        }
    }
    #[cfg(unix)]
    #[test]
    fn static_symlink_at_root_stage_marker_or_payload_never_follows_target() {
        use std::os::unix::fs::symlink;
        for kind in ["root", "stage", "marker", "payload"] {
            let f = Fixture::new();
            let outside = Fixture::new();
            // The target deliberately has a fully valid matching owner marker;
            // a failed marker check must not mask a missing no-follow guarantee.
            let target_stage = outside.path.join(&f.id);
            fs::create_dir(&target_stage).unwrap();
            fs::write(
                target_stage.join("owner.json"),
                serde_json::json!({"format":FORMAT,"id":f.id,"count":2}).to_string(),
            )
            .unwrap();
            let target = target_stage.join("source-0");
            fs::write(&target, "outside").unwrap();
            match kind {
                "root" => {
                    fs::rename(&f.path, f.path.with_extension("held")).unwrap();
                    symlink(&outside.path, &f.path).unwrap();
                }
                "stage" => {
                    fs::remove_dir_all(f.stage()).unwrap();
                    symlink(&target_stage, f.stage()).unwrap();
                }
                "marker" => {
                    fs::remove_file(f.stage().join("owner.json")).unwrap();
                    symlink(
                        target_stage.join("owner.json"),
                        f.stage().join("owner.json"),
                    )
                    .unwrap();
                }
                _ => symlink(&target, f.stage().join("source-1")).unwrap(),
            }
            let report = f.run();
            assert_eq!(report.removed_files, 0, "{kind}");
            assert_eq!(fs::read(&target).unwrap(), b"outside");
            if kind == "root" {
                fs::remove_file(&f.path).unwrap();
                fs::rename(f.path.with_extension("held"), &f.path).unwrap();
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn symlink_in_root_ancestor_is_rejected_before_marker_access() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let outside = Fixture::new();
        let child = f.path.join("child");
        fs::create_dir(&child).unwrap();
        fs::rename(f.stage(), child.join(&f.id)).unwrap();
        symlink(&f.path, outside.path.join("alias")).unwrap();
        let report = cleanup(&outside.path.join("alias/child"), &f.id, || ());
        assert_eq!(report.removed_files, 0);
        assert_eq!(report.failed, 1);
        assert_eq!(
            fs::read(child.join(&f.id).join("source-0")).unwrap(),
            b"payload"
        );
    }
    #[cfg(unix)]
    #[test]
    fn replacing_parent_path_after_preflight_cannot_redirect_deletion() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let outside = Fixture::new();
        fs::create_dir(outside.path.join(&f.id)).unwrap();
        fs::write(outside.path.join(&f.id).join("source-0"), "outside").unwrap();
        let held = f.path.with_extension("held");
        let report = cleanup(&f.path, &f.id, || {
            fs::rename(&f.path, &held).unwrap();
            symlink(&outside.path, &f.path).unwrap();
        });
        assert_eq!(report.removed_stages, 1);
        assert_eq!(report.unlinked_bytes, 7);
        assert_eq!(
            fs::read(outside.path.join(&f.id).join("source-0")).unwrap(),
            b"outside"
        );
        fs::remove_file(&f.path).unwrap();
        fs::rename(held, &f.path).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn replacing_stage_path_after_preflight_never_deletes_replacement_payload() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let outside = Fixture::new();
        let held = f.path.join("held-original");
        let report = cleanup(&f.path, &f.id, || {
            fs::rename(f.stage(), &held).unwrap();
            symlink(outside.stage(), f.stage()).unwrap();
        });
        assert_eq!(report.removed_stages, 0);
        assert_eq!(report.removed_files, 1);
        assert_eq!(
            fs::read(outside.stage().join("source-0")).unwrap(),
            b"payload"
        );
        assert!(!held.join("source-0").exists());
    }
    #[test]
    fn late_unknown_file_is_retained_without_recursive_removal() {
        let f = Fixture::new();
        let report = cleanup(&f.path, &f.id, || {
            fs::write(f.stage().join("late-unknown"), "keep").unwrap()
        });
        assert_eq!(report.removed_stages, 0);
        assert_eq!(report.failed, 1);
        assert_eq!(fs::read(f.stage().join("late-unknown")).unwrap(), b"keep");
    }
}
