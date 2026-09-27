/// Set the private application-support registry before native receiving starts.
/// This does not scan or delete files in any destination.
pub async fn configure_receive_cache_registry(directory: String) -> anyhow::Result<()> {
    tokio::task::spawn_blocking(move || localsend::receive_registry::configure(directory.into()))
        .await??;
    Ok(())
}

/// Bounded worker cleanup of registered, unlocked non-resumable attempts.
/// Returns aggregate counts/reasons, never native paths or access credentials.
pub async fn cleanup_receive_cache_registry(limit: u32) -> anyhow::Result<String> {
    let report =
        tokio::task::spawn_blocking(move || localsend::receive_registry::cleanup(limit as usize))
            .await??;
    Ok(localsend::serde_json::to_string(&report)?)
}

/// Bounded, read-only inventory of registered caches and cleanup eligibility.
/// Returns opaque record IDs and display names, never paths or credentials.
pub async fn inspect_receive_cache_registry(limit: u32) -> anyhow::Result<String> {
    let report =
        tokio::task::spawn_blocking(move || localsend::receive_registry::inspect(limit as usize))
            .await??;
    Ok(localsend::serde_json::to_string(&report)?)
}

/// Configure local native-receive crash-residue retention. Modes: immediate,
/// days (1..3650), manual; days must be absent for the other modes. The app
/// persists this preference. Invalid input leaves the current policy unchanged.
/// Returns {"mode":"immediate"|"days"|"manual","days":null|number}.
pub async fn configure_receive_cache_retention_policy(
    mode: String,
    days: Option<u32>,
) -> anyhow::Result<String> {
    let policy = tokio::task::spawn_blocking(move || {
        localsend::receive_registry::configure_retention_policy(&mode, days)
    })
    .await??;
    Ok(localsend::serde_json::to_string(&policy)?)
}

/// Explicit user cleanup, ignoring age only. Active/identity protections remain.
pub async fn cleanup_receive_cache_registry_now(limit: u32) -> anyhow::Result<String> {
    let report = tokio::task::spawn_blocking(move || {
        localsend::receive_registry::cleanup_now(limit as usize)
    })
    .await??;
    Ok(localsend::serde_json::to_string(&report)?)
}

/// Read-only preview for explicit cleanup-now; ignores age, not safety checks.
pub async fn inspect_receive_cache_registry_now(limit: u32) -> anyhow::Result<String> {
    let report = tokio::task::spawn_blocking(move || {
        localsend::receive_registry::inspect_now(limit as usize)
    })
    .await??;
    Ok(localsend::serde_json::to_string(&report)?)
}

/// Return the effective local preference, not a persisted application setting.
pub async fn get_receive_cache_retention_policy() -> anyhow::Result<String> {
    let policy =
        tokio::task::spawn_blocking(localsend::receive_registry::retention_policy).await??;
    Ok(localsend::serde_json::to_string(&policy)?)
}

/// Runs under a native-approved coordinated directory lease held by the caller.
/// Only registered non-resumable residues inside this root are considered;
/// activity locks, identity proofs and retention remain mandatory.
pub async fn maintain_receive_cache_registry_in_scope(
    directory: String,
    limit: u32,
    inspection: bool,
    force: bool,
) -> anyhow::Result<String> {
    let report = tokio::task::spawn_blocking(move || {
        localsend::receive_registry::maintain_in_scope(
            directory.into(),
            limit as usize,
            inspection,
            force,
        )
    })
    .await??;
    Ok(localsend::serde_json::to_string(&report)?)
}
