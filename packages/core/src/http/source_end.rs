//! Optional receiver-issued authority for ending one inactive durable source.
//! Secrets deliberately have neither Debug nor Display implementations.
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceEndGrant {
    pub version: u32,
    pub grant_id: String,
    pub round: String,
    pub token: String,
    pub expires_at_unix_ms: u64,
}
impl SourceEndGrant {
    pub fn valid(&self) -> bool {
        use base64::Engine;
        self.version == 1
            && valid_uuid(&self.grant_id)
            && valid_uuid(&self.round)
            && self.expires_at_unix_ms > 0
            && base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(&self.token)
                .is_ok_and(|v| v.len() == 32)
    }
}
pub(crate) fn valid_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|v| v.to_string() == value)
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SourceEndOutcome {
    Cleared,
    PublishedPreserved,
    Active,
    PublicationPending,
    RetainedUnknown,
    UnknownOrExpired,
    Superseded,
    AuthorizationRequired,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceEndResult {
    pub outcome: SourceEndOutcome,
    pub receipt_id: Option<String>,
    pub removed_files: u32,
    pub unlinked_bytes: u64,
}
impl SourceEndResult {
    pub(crate) fn new(outcome: SourceEndOutcome) -> Self {
        Self {
            outcome,
            receipt_id: None,
            removed_files: 0,
            unlinked_bytes: 0,
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceEndRequest {
    pub version: u32,
    pub request_id: String,
    pub grant_id: String,
    pub round: String,
    pub token: String,
}
impl SourceEndRequest {
    pub fn valid(&self) -> bool {
        valid_uuid(&self.request_id)
            && SourceEndGrant {
                version: self.version,
                grant_id: self.grant_id.clone(),
                round: self.round.clone(),
                token: self.token.clone(),
                expires_at_unix_ms: 1,
            }
            .valid()
    }
}

/// Private host delivery barrier. The sender must persist the grant before
/// acknowledging true; a failed/absent acknowledgement sends no payload block.
pub enum SourceEndEvent {
    Grant {
        grant: SourceEndGrant,
        persisted: tokio::sync::oneshot::Sender<bool>,
    },
    Unavailable,
}
pub type SourceEndCallback = std::sync::Arc<dyn Fn(SourceEndEvent) + Send + Sync>;
