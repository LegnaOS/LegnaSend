//! Private bounded capability ledger. Every mutation runs under real registry
//! and record locks; knowing a recovery key or an old v2 token grants no access.
use super::*;
use crate::http::source_end::{
    SourceEndGrant, SourceEndOutcome as Outcome, SourceEndRequest, SourceEndResult,
};
use base64::Engine;
use ring::rand::SecureRandom;
use subtle::ConstantTimeEq;
const LEDGER: &str = ".source-end";
const MAX_GRANTS: usize = 256;
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Reference {
    grant_id: String,
    round: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GrantRecord {
    reference: Reference,
    record_key: String,
    task_id: String,
    peer: Peer,
    token_hash: String,
    created: u64,
    expires: u64,
    proof: Option<SourceEndResult>,
}
impl GrantRecord {
    fn valid(&self, name: &str) -> bool {
        crate::http::source_end::valid_uuid(&self.reference.grant_id)
            && crate::http::source_end::valid_uuid(&self.reference.round)
            && crate::http::source_end::valid_uuid(&self.task_id)
            && name == grant_name(&self.reference.grant_id)
            && self.record_key.len() == 64
            && self.record_key.bytes().all(|b| b.is_ascii_hexdigit())
            && self.token_hash.len() == 64
            && self.token_hash.bytes().all(|b| b.is_ascii_hexdigit())
            && self.peer.valid()
            && self.expires > self.created
            && self.expires - self.created <= LEASE_MS
            && self.proof.as_ref().is_none_or(|p| {
                matches!(p.outcome, Outcome::Cleared | Outcome::PublishedPreserved)
                    && p.receipt_id
                        .as_ref()
                        .is_some_and(|id| crate::http::source_end::valid_uuid(id))
                    && p.removed_files <= 2
            })
    }
}
fn ledger(root: &Dir) -> Result<Dir> {
    match root.create_dir(LEDGER) {
        Ok(()) => sync_dir(root)?,
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    Ok(root.open_dir_nofollow(LEDGER)?)
}
fn grant_name(id: &str) -> String {
    format!("{id}.json")
}
pub(crate) enum SourceEndPreflight {
    Complete(SourceEndResult),
    Ready,
    Scope(PathBuf),
}
enum PreparedSourceEnd {
    Complete(SourceEndResult),
    Pending(Lease),
}

impl Registry {
    /// The fresh approved attachment already owns its record lock. Rotation is
    /// committed before a grant is returned. Even an older sender revokes the
    /// previous attachment's authority by clearing its reference.
    pub(crate) fn rotate_source_end(
        &self,
        lease: &mut Lease,
        enabled: bool,
    ) -> Result<Option<SourceEndGrant>> {
        let _index = self.index_lock()?;
        if !enabled {
            if lease.record.source_end.take().is_some() {
                atomic(&lease.directory, "record.json", &lease.record)?;
            }
            return Ok(None);
        }
        let dir = ledger(&self.dir)?;
        let now = now_ms()?;
        if now < lease.record.created_unix_ms || now >= lease.record.expires_unix_ms {
            return Err(Error::Expired);
        }
        let mut count = 0;
        // Unknown files count toward the bound; never delete them. At most one
        // bounded ledger scan per actual attachment, never a recursive walk.
        let mut scanned = 0;
        for entry in dir.entries()?.take(MAX_GRANTS + 1) {
            scanned += 1;
            let entry = entry?;
            let name = entry.file_name();
            let expired = name
                .to_str()
                .and_then(|n| decode::<GrantRecord>(&dir, n).ok().filter(|g| g.valid(n)))
                .is_some_and(|g| g.expires <= now && g.created <= now);
            if expired && entry.file_type()?.is_file() {
                dir.remove_file(&name)?;
            } else {
                count += 1;
            }
        }
        if count >= MAX_GRANTS || scanned > MAX_GRANTS {
            return Err(Error::Capacity);
        }
        let reference = Reference {
            grant_id: uuid::Uuid::new_v4().to_string(),
            round: uuid::Uuid::new_v4().to_string(),
        };
        let mut random = [0u8; 32];
        ring::rand::SystemRandom::new()
            .fill(&mut random)
            .map_err(|_| Error::Invalid)?;
        let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random);
        let record = GrantRecord {
            reference: reference.clone(),
            record_key: lease.record.key(),
            task_id: lease.record.cache.task_id.clone(),
            peer: lease.record.source.peer.clone(),
            token_hash: sha256_hex(token.as_bytes()),
            created: now,
            expires: lease.record.expires_unix_ms,
            proof: None,
        };
        atomic(&dir, &grant_name(&reference.grant_id), &record)?;
        lease.record.source_end = Some(reference.clone());
        atomic(&lease.directory, "record.json", &lease.record)?;
        Ok(Some(SourceEndGrant {
            version: 1,
            grant_id: reference.grant_id,
            round: reference.round,
            token,
            expires_at_unix_ms: record.expires,
        }))
    }
    fn prepare_source_end(
        &self,
        request: &SourceEndRequest,
        peer: &Peer,
    ) -> Result<PreparedSourceEnd> {
        if !request.valid() {
            return Err(Error::Invalid);
        }
        let _index = self.index_lock()?;
        let dir = match self.dir.open_dir_nofollow(LEDGER) {
            Ok(dir) => dir,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                    Outcome::UnknownOrExpired,
                )));
            }
            Err(e) => return Err(e.into()),
        };
        let grant: GrantRecord = match decode(&dir, &grant_name(&request.grant_id)) {
            Ok(g) => g,
            Err(Error::Io(e)) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                    Outcome::UnknownOrExpired,
                )));
            }
            Err(e) => return Err(e),
        };
        if !grant.valid(&grant_name(&request.grant_id)) {
            return Err(Error::Identity);
        }
        // No identity-dependent result before secret and transport identity pass.
        let hash = sha256_hex(request.token.as_bytes());
        if !bool::from(hash.as_bytes().ct_eq(grant.token_hash.as_bytes()))
            || &grant.peer != peer
            || grant.reference.grant_id != request.grant_id
            || grant.reference.round != request.round
        {
            return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                Outcome::AuthorizationRequired,
            )));
        }
        let now = now_ms()?;
        if now < grant.created || now >= grant.expires {
            return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                Outcome::UnknownOrExpired,
            )));
        }
        if let Some(proof) = grant.proof {
            return Ok(PreparedSourceEnd::Complete(proof));
        }
        let directory = match self.dir.open_dir_nofollow(&grant.record_key) {
            Ok(d) => d,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                    Outcome::RetainedUnknown,
                )));
            }
            Err(e) => return Err(e.into()),
        };
        let file = open_file(&directory, ".active.lock", false)?;
        match lock(&file) {
            Ok(()) => {}
            Err(Error::Busy) => {
                return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                    Outcome::Active,
                )));
            }
            Err(e) => return Err(e),
        }
        let record: Record = decode(&directory, "record.json")?;
        let state: State = decode(&directory, "state.json")?;
        if !record.valid() || record.key() != grant.record_key {
            return Err(Error::Identity);
        }
        if record.source_end.as_ref() != Some(&grant.reference)
            || record.cache.task_id != grant.task_id
        {
            return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                Outcome::Superseded,
            )));
        }
        if matches!(state, State::Published { .. }) {
            let mut result = SourceEndResult::new(Outcome::PublishedPreserved);
            result.receipt_id = Some(record.receipt_id.clone());
            return Ok(PreparedSourceEnd::Complete(result));
        }
        if matches!(state, State::Publishing { .. }) {
            return Ok(PreparedSourceEnd::Complete(SourceEndResult::new(
                Outcome::PublicationPending,
            )));
        }
        // Only private ledger and registry data were touched. Drop the short
        // index lock and record lease before awaiting any native coordinator.
        Ok(PreparedSourceEnd::Pending(Lease {
            registry_dir: self.dir.try_clone()?,
            directory,
            _lock: file,
            record,
            state,
        }))
    }

    pub(crate) fn preflight_source_end(
        &self,
        request: &SourceEndRequest,
        peer: &Peer,
    ) -> Result<SourceEndPreflight> {
        self.preflight_source_end_with_policy(
            request,
            peer,
            crate::receive_scope_policy::requires_coordinated_access,
        )
    }

    pub(crate) fn preflight_source_end_with_policy(
        &self,
        request: &SourceEndRequest,
        peer: &Peer,
        requires_scope: impl FnOnce(&Path) -> bool,
    ) -> Result<SourceEndPreflight> {
        match self.prepare_source_end(request, peer)? {
            PreparedSourceEnd::Complete(result) => Ok(SourceEndPreflight::Complete(result)),
            PreparedSourceEnd::Pending(lease) => {
                if requires_scope(&lease.record.target.approved_root) {
                    Ok(SourceEndPreflight::Scope(
                        lease.record.target.approved_root.clone(),
                    ))
                } else {
                    Ok(SourceEndPreflight::Ready)
                }
            }
        }
    }

    pub(crate) fn end_source(
        &self,
        request: &SourceEndRequest,
        peer: &Peer,
    ) -> Result<SourceEndResult> {
        match self.prepare_source_end(request, peer)? {
            PreparedSourceEnd::Complete(result) => Ok(result),
            PreparedSourceEnd::Pending(lease) => {
                if crate::receive_scope_policy::requires_coordinated_access(
                    &lease.record.target.approved_root,
                ) {
                    return Ok(SourceEndResult::new(Outcome::RetainedUnknown));
                }
                self.finish_source_end(lease, request, None)
            }
        }
    }

    pub(crate) fn end_source_in_scope(
        &self,
        request: &SourceEndRequest,
        peer: &Peer,
        scope: &crate::receive_scope_policy::CoordinatedRoot,
    ) -> Result<SourceEndResult> {
        // Recheck the secret, transport identity, grant round, time and record
        // after native authorization. A stale decision never authorizes a new root.
        match self.prepare_source_end(request, peer)? {
            PreparedSourceEnd::Complete(result) => Ok(result),
            PreparedSourceEnd::Pending(lease) => {
                if lease.record.target.approved_root != scope.path() {
                    return Err(Error::Identity);
                }
                self.finish_source_end(lease, request, Some(scope))
            }
        }
    }

    fn finish_source_end(
        &self,
        mut lease: Lease,
        request: &SourceEndRequest,
        scope: Option<&crate::receive_scope_policy::CoordinatedRoot>,
    ) -> Result<SourceEndResult> {
        let mut removed = (0, 0);
        match scope {
            Some(scope) => lease.discard_report_in_scope(&mut removed, scope)?,
            None => lease.discard_report(&mut removed)?,
        }
        let dir = self.dir.open_dir_nofollow(LEDGER)?;
        let proof: GrantRecord = decode(&dir, &grant_name(&request.grant_id))?;
        let result = proof.proof.ok_or(Error::Identity)?;
        self.retire(lease)?;
        Ok(result)
    }
}
impl Lease {
    pub(super) fn record_source_end_cleanup(
        &self,
        published: bool,
        bytes: u64,
        files: u32,
    ) -> Result<()> {
        let Some(reference) = &self.record.source_end else {
            return Ok(());
        };
        let dir = self.registry_dir.open_dir_nofollow(LEDGER)?;
        let name = grant_name(&reference.grant_id);
        let mut grant: GrantRecord = match decode(&dir, &name) {
            Ok(g) => g,
            // Expired private grants may have been pruned. No live authority can
            // then claim a successful cleanup; the endpoint returns unknown.
            Err(Error::Io(e))
                if e.kind() == io::ErrorKind::NotFound
                    && now_ms()? >= self.record.expires_unix_ms =>
            {
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        if !grant.valid(&name)
            || grant.reference != *reference
            || grant.record_key != self.record.key()
            || grant.task_id != self.record.cache.task_id
        {
            return Err(Error::Identity);
        }
        if grant.proof.is_none() {
            grant.proof = Some(SourceEndResult {
                outcome: if published {
                    Outcome::PublishedPreserved
                } else {
                    Outcome::Cleared
                },
                receipt_id: Some(self.record.receipt_id.clone()),
                removed_files: files,
                unlinked_bytes: bytes,
            });
            // Durable cleanup proof precedes removing the original record.
            atomic(&dir, &name, &grant)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        registry: Arc<Registry>,
        source: Source,
        target: Target,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("legna-end-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(root.join("journal")).unwrap();
            std::fs::create_dir(root.join("received")).unwrap();
            let root = std::fs::canonicalize(root).unwrap();
            let registry = Registry::open(&root.join("journal")).unwrap();
            let source = Source {
                resume_key: uuid::Uuid::new_v4().to_string(),
                peer: Peer::Http {
                    address: "127.0.0.1".into(),
                },
                sha256: "a".repeat(64),
                size: BLOCK as u64,
            };
            let target = Target::new(
                &root.join("received"),
                "file.bin",
                &root.join("received/file.bin"),
            )
            .unwrap();
            Self {
                root,
                registry,
                source,
                target,
            }
        }
        fn create(&self) -> Lease {
            let identity =
                Registry::identity(&self.source, &self.target, now_ms().unwrap()).unwrap();
            let path = self
                .target
                .parent
                .join(format!(".legnasend-receive-{}.ls", identity.task_id));
            let mut file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(path)
                .unwrap();
            file.write_all(b"owned-cache-bytes").unwrap();
            self.registry
                .create(
                    self.source.clone(),
                    self.target.clone(),
                    identity,
                    &file,
                    uuid::Uuid::new_v4().to_string(),
                )
                .unwrap()
        }
        fn claim(&self) -> Lease {
            self.registry
                .claim(&self.source, &self.root.join("received"), "file.bin")
                .unwrap()
                .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn request(grant: &SourceEndGrant) -> SourceEndRequest {
        SourceEndRequest {
            version: 1,
            request_id: uuid::Uuid::new_v4().to_string(),
            grant_id: grant.grant_id.clone(),
            round: grant.round.clone(),
            token: grant.token.clone(),
        }
    }
    #[test]
    fn authority_cannot_delete_active_wrong_peer_or_rotated_record_and_cleanup_replays() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        let req = request(&grant);
        let raw = std::fs::read_to_string(
            f.root
                .join("journal/.source-end")
                .join(grant_name(&grant.grant_id)),
        )
        .unwrap();
        assert!(!raw.contains(&grant.token));
        assert_eq!(
            f.registry.end_source(&req, &f.source.peer).unwrap().outcome,
            Outcome::Active
        );
        assert_eq!(
            f.registry
                .end_source(
                    &req,
                    &Peer::Http {
                        address: "127.0.0.2".into()
                    }
                )
                .unwrap()
                .outcome,
            Outcome::AuthorizationRequired
        );
        let mut wrong = request(&grant);
        wrong.token = "A".repeat(43);
        assert_eq!(
            f.registry
                .end_source(&wrong, &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::AuthorizationRequired
        );
        lease.suspend().unwrap();
        drop(lease);
        let mut lease = f.claim();
        let newer = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        lease.suspend().unwrap();
        drop(lease);
        assert_eq!(
            f.registry.end_source(&req, &f.source.peer).unwrap().outcome,
            Outcome::Superseded
        );
        let result = f
            .registry
            .end_source(&request(&newer), &f.source.peer)
            .unwrap();
        assert_eq!(result.outcome, Outcome::Cleared);
        assert_eq!(result.removed_files, 1);
        assert_eq!(result.unlinked_bytes, 17);
        let repeated = f
            .registry
            .end_source(&request(&newer), &f.source.peer)
            .unwrap();
        assert_eq!(result.receipt_id, repeated.receipt_id);
        assert_eq!(result.unlinked_bytes, repeated.unlinked_bytes);
        assert_eq!(
            std::fs::read_dir(f.root.join("received")).unwrap().count(),
            0
        );
    }
    #[test]
    fn explicit_local_discard_records_proof_before_retire_and_unknown_is_not_success() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        lease.discard().unwrap();
        f.registry.retire(lease).unwrap();
        assert_eq!(
            f.registry
                .end_source(&request(&grant), &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::Cleared
        );
        let mut unknown = request(&grant);
        unknown.grant_id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            f.registry
                .end_source(&unknown, &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::UnknownOrExpired
        );
    }
    #[test]
    fn publication_evidence_is_never_deleted_by_end_notice() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        let destination = f.root.join("received/file.bin");
        std::fs::write(&destination, b"published").unwrap();
        let stamp = Stamp::of(&Metadata::from_file(&File::open(&destination).unwrap()).unwrap());
        lease
            .write_state(State::Publishing {
                staging_stamp: stamp.clone(),
            })
            .unwrap();
        drop(lease);
        assert_eq!(
            f.registry
                .end_source(&request(&grant), &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::PublicationPending
        );
        let mut lease = f.claim();
        lease
            .write_state(State::Published {
                final_stamp: stamp,
                completed_unix_ms: now_ms().unwrap(),
            })
            .unwrap();
        drop(lease);
        assert_eq!(
            f.registry
                .end_source(&request(&grant), &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::PublishedPreserved
        );
        assert_eq!(std::fs::read(&destination).unwrap(), b"published");
    }
    #[test]
    fn scoped_preflight_authenticates_before_exposing_private_approved_root() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        lease.suspend().unwrap();
        drop(lease);
        for mismatch in [false, true] {
            let mut req = request(&grant);
            let peer = if mismatch {
                Peer::Http {
                    address: "127.0.0.2".into(),
                }
            } else {
                req.token = "A".repeat(43);
                f.source.peer.clone()
            };
            assert!(matches!(
                f.registry
                    .preflight_source_end_with_policy(&req, &peer, |_| panic!(
                        "Wrong authority reached scope routing"
                    ))
                    .unwrap(),
                SourceEndPreflight::Complete(SourceEndResult {
                    outcome: Outcome::AuthorizationRequired,
                    ..
                })
            ));
        }
        // Preflight reads only private metadata, even if the provider root is gone.
        std::fs::rename(f.root.join("received"), f.root.join("offline")).unwrap();
        assert!(
            matches!(f.registry.preflight_source_end_with_policy(&request(&grant), &f.source.peer, |_| true).unwrap(),
            SourceEndPreflight::Scope(root) if root == f.target.approved_root)
        );
    }

    #[test]
    fn scoped_source_end_revalidates_rotation_root_and_preserves_receipt_replay() {
        let f = Fixture::new();
        let mut lease = f.create();
        let old = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        lease.suspend().unwrap();
        drop(lease);
        assert!(matches!(
            f.registry
                .preflight_source_end_with_policy(&request(&old), &f.source.peer, |_| true)
                .unwrap(),
            SourceEndPreflight::Scope(_)
        ));
        let mut lease = f.claim();
        let current = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        lease.suspend().unwrap();
        drop(lease);
        let root =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        assert_eq!(
            f.registry
                .end_source_in_scope(&request(&old), &f.source.peer, &root)
                .unwrap()
                .outcome,
            Outcome::Superseded
        );
        std::fs::create_dir(f.root.join("wrong")).unwrap();
        let wrong =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("wrong")).unwrap();
        assert!(matches!(
            f.registry
                .end_source_in_scope(&request(&current), &f.source.peer, &wrong),
            Err(Error::Identity)
        ));
        let result = f
            .registry
            .end_source_in_scope(&request(&current), &f.source.peer, &root)
            .unwrap();
        assert_eq!(result.outcome, Outcome::Cleared);
        assert_eq!(result.removed_files, 1);
        assert_eq!(result.unlinked_bytes, 17);
        let replay = f
            .registry
            .end_source_in_scope(&request(&current), &f.source.peer, &root)
            .unwrap();
        assert_eq!(replay.receipt_id, result.receipt_id);
        assert_eq!(replay.unlinked_bytes, result.unlinked_bytes);
    }

    #[test]
    fn scoped_source_end_rejects_replaced_root_without_touching_new_user_files() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        let cache = lease.record.cache_name();
        lease.suspend().unwrap();
        drop(lease);
        std::fs::rename(f.root.join("received"), f.root.join("old")).unwrap();
        std::fs::create_dir(f.root.join("received")).unwrap();
        std::fs::write(f.root.join("received").join(&cache), b"replacement").unwrap();
        let scope =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        assert!(matches!(
            f.registry
                .end_source_in_scope(&request(&grant), &f.source.peer, &scope),
            Err(Error::Identity)
        ));
        assert_eq!(
            std::fs::read(f.root.join("received").join(&cache)).unwrap(),
            b"replacement"
        );
        assert_eq!(
            std::fs::read(f.root.join("old").join(cache)).unwrap(),
            b"owned-cache-bytes"
        );
    }

    #[test]
    fn scoped_durable_scan_covers_children_retention_active_other_roots_and_inspection() {
        let mut f = Fixture::new();
        std::fs::create_dir(f.root.join("received/nested")).unwrap();
        f.target = Target::new(
            &f.root.join("received"),
            "nested/file.bin",
            &f.root.join("received/nested/file.bin"),
        )
        .unwrap();
        let mut first = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut first, true)
            .unwrap()
            .unwrap();
        let scope =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        let active = f.registry.scan_in_scope(&scope, 128, true, false).unwrap();
        assert_eq!(active.active, 1);
        assert_eq!(active.removed_files, 0);
        first.suspend().unwrap();
        drop(first);
        std::fs::create_dir(f.root.join("other")).unwrap();
        f.target = Target::new(
            &f.root.join("other"),
            "file.bin",
            &f.root.join("other/file.bin"),
        )
        .unwrap();
        let mut other = f.create();
        other.suspend().unwrap();
        drop(other);
        let retained = f.registry.scan_in_scope(&scope, 128, false, false).unwrap();
        assert_eq!(retained.examined, 1);
        assert_eq!(retained.retained, 1);
        let preview = f.registry.scan_in_scope(&scope, 128, true, true).unwrap();
        assert_eq!(preview.examined, 1);
        assert_eq!(preview.planned_bytes, 17);
        assert_eq!(preview.removed_files, 0);
        assert_eq!(preview.retained, 0);
        assert_eq!(preview.entries.len(), 1);
        assert_eq!(preview.entries[0].source_kind, "nativeReceive");
        assert_eq!(preview.entries[0].disposition, "candidate");
        let clean = f.registry.scan_in_scope(&scope, 128, true, false).unwrap();
        assert_eq!(clean.examined, 1);
        assert_eq!(clean.removed_files, 1);
        assert_eq!(clean.unlinked_bytes, 17);
        assert_eq!(clean.entries[0].id, preview.entries[0].id);
        assert_eq!(std::fs::read_dir(f.root.join("other")).unwrap().count(), 1);
        assert_eq!(
            f.registry
                .end_source(&request(&grant), &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::Cleared
        );
    }

    #[test]
    fn scoped_durable_scan_preserves_published_file_and_changed_parent() {
        let f = Fixture::new();
        let mut lease = f.create();
        let grant = f
            .registry
            .rotate_source_end(&mut lease, true)
            .unwrap()
            .unwrap();
        let destination = f.root.join("received/file.bin");
        std::fs::write(&destination, b"published").unwrap();
        let stamp = Stamp::of(&Metadata::from_file(&File::open(&destination).unwrap()).unwrap());
        lease
            .write_state(State::Published {
                final_stamp: stamp,
                completed_unix_ms: now_ms().unwrap(),
            })
            .unwrap();
        drop(lease);
        let scope =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        let report = f.registry.scan_in_scope(&scope, 128, true, false).unwrap();
        assert_eq!(report.removed_files, 1);
        assert_eq!(std::fs::read(destination).unwrap(), b"published");
        assert_eq!(
            f.registry
                .end_source(&request(&grant), &f.source.peer)
                .unwrap()
                .outcome,
            Outcome::PublishedPreserved
        );
    }
    #[test]
    fn abandoned_provider_lease_retains_private_state_then_coordinated_expiry_can_clean() {
        let f = Fixture::new();
        let mut lease = f.create();
        lease.record.created_unix_ms = now_ms().unwrap() - LEASE_MS - 1;
        lease.record.expires_unix_ms = lease.record.created_unix_ms + LEASE_MS;
        lease.record.cache.created_unix_ms = lease.record.created_unix_ms;
        atomic(&lease.directory, "record.json", &lease.record).unwrap();
        let key = lease.record.key();
        let cache = lease.record.cache_name();
        let journal = f.root.join("journal").join(&key);
        let before = std::fs::read(journal.join("state.json")).unwrap();
        // The no-target path may outlive Dart's scope. Its only permitted action
        // is dropping private registry ownership, even if the root disappeared.
        std::fs::rename(f.root.join("received"), f.root.join("offline")).unwrap();
        drop(lease);
        assert_eq!(std::fs::read(journal.join("state.json")).unwrap(), before);
        assert_eq!(
            std::fs::read(f.root.join("offline").join(&cache)).unwrap(),
            b"owned-cache-bytes"
        );
        std::fs::rename(f.root.join("offline"), f.root.join("received")).unwrap();
        let scope =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        let report = f.registry.scan_in_scope(&scope, 128, false, false).unwrap();
        assert_eq!(report.removed_files, 1);
        assert_eq!(report.removed_records, 1);
        assert!(!journal.exists());
    }
    #[test]
    fn scoped_durable_scan_requires_approved_root_and_unchanged_descendant_parent() {
        let mut f = Fixture::new();
        let parent = f.root.join("received/nested");
        std::fs::create_dir(&parent).unwrap();
        f.target = Target::new(
            &f.root.join("received"),
            "nested/file.bin",
            &parent.join("file.bin"),
        )
        .unwrap();
        let mut lease = f.create();
        let cache = lease.record.cache_name();
        lease.suspend().unwrap();
        drop(lease);
        let too_narrow = crate::receive_scope_policy::CoordinatedRoot::open(&parent).unwrap();
        let skipped = f
            .registry
            .scan_in_scope(&too_narrow, 128, true, false)
            .unwrap();
        assert_eq!(skipped.examined, 0);
        assert!(parent.join(&cache).exists());
        std::fs::rename(&parent, f.root.join("received/old-nested")).unwrap();
        std::fs::create_dir(&parent).unwrap();
        std::fs::write(parent.join(&cache), b"new user file").unwrap();
        let scope =
            crate::receive_scope_policy::CoordinatedRoot::open(&f.root.join("received")).unwrap();
        let retained = f.registry.scan_in_scope(&scope, 128, true, false).unwrap();
        assert_eq!(retained.examined, 1);
        assert_eq!(retained.retained, 1);
        assert_eq!(retained.removed_files, 0);
        assert_eq!(
            std::fs::read(parent.join(&cache)).unwrap(),
            b"new user file"
        );
        assert_eq!(
            std::fs::read(f.root.join("received/old-nested").join(cache)).unwrap(),
            b"owned-cache-bytes"
        );
    }
}
