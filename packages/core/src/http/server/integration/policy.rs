use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hyper::{HeaderMap, header};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fmt,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU16, Ordering},
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
pub enum Scope {
    #[serde(rename = "nativeTasks.read")]
    NativeTasksRead,
    #[serde(rename = "nativeTasks.control")]
    NativeTasksControl,
    #[serde(rename = "service.read")]
    Service,
    #[serde(rename = "workspaces.read")]
    Workspaces,
    #[serde(rename = "files.read")]
    Files,
    #[serde(rename = "requests.read")]
    Requests,
    #[serde(rename = "requests.manage")]
    RequestsManage,
    #[serde(rename = "keys.manage")]
    KeysManage,
    #[serde(rename = "files.upload")]
    Upload,
    #[serde(rename = "workspaces.manage")]
    Manage,
    #[serde(rename = "devices.read")]
    DevicesRead,
    #[serde(rename = "devices.scan")]
    DevicesScan,
    #[serde(rename = "transfers.read")]
    TransfersRead,
    #[serde(rename = "transfers.send")]
    TransfersSend,
    #[serde(rename = "transfers.control")]
    TransfersControl,
    #[serde(rename = "cache.read")]
    CacheRead,
    #[serde(rename = "cache.clean")]
    CacheClean,
    #[serde(rename = "settings.read")]
    SettingsRead,
    #[serde(rename = "settings.write")]
    SettingsWrite,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceGrant {
    pub scopes: Vec<Scope>,
    pub workspaces: Vec<String>,
}
impl WorkspaceGrant {
    pub(crate) fn allows(&self, workspace: &str) -> bool {
        self.workspaces
            .iter()
            .any(|id| id == "*" || id == workspace)
    }
    fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.scopes.len() <= 19
                && self.scopes.iter().collect::<HashSet<_>>().len() == self.scopes.len(),
            "Invalid scope set"
        );
        anyhow::ensure!(
            self.workspaces.len() <= 256
                && self.workspaces.iter().collect::<HashSet<_>>().len() == self.workspaces.len(),
            "Invalid workspace set"
        );
        anyhow::ensure!(
            self.workspaces
                .iter()
                .all(|id| id == "*" || uuid::Uuid::parse_str(id).is_ok()),
            "Invalid workspace identity"
        );
        anyhow::ensure!(
            !self.workspaces.iter().any(|id| id == "*") || self.workspaces.len() == 1,
            "Invalid wildcard grant"
        );
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Limits {
    pub per_second: u32,
    pub per_minute: u32,
    pub concurrent: u32,
}
impl Limits {
    fn validate(self) -> anyhow::Result<()> {
        anyhow::ensure!(
            (0..=1000).contains(&self.per_second)
                && (0..=60000).contains(&self.per_minute)
                && (0..=64).contains(&self.concurrent),
            "Invalid API limits"
        );
        Ok(())
    }
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct KeyRecord {
    pub id: String,
    pub name: String,
    pub verifier: String,
    pub grant: WorkspaceGrant,
    pub expires_at: Option<u64>,
    pub created_at: u64,
    #[serde(default = "key_enabled_default")]
    pub enabled: bool,
    #[serde(default)]
    pub limits: Option<Limits>,
}
fn key_enabled_default() -> bool {
    true
}
impl fmt::Debug for KeyRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyRecord")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}
impl KeyRecord {
    fn validate(&self) -> anyhow::Result<[u8; 32]> {
        anyhow::ensure!(
            uuid::Uuid::parse_str(&self.id)
                .is_ok_and(|id| id.to_string().eq_ignore_ascii_case(&self.id)),
            "Invalid key identity"
        );
        anyhow::ensure!(
            !self.name.trim().is_empty()
                && self.name.len() <= 256
                && !self.name.chars().any(char::is_control),
            "Invalid key name"
        );
        anyhow::ensure!(
            self.verifier.len() == 64 && self.verifier.as_bytes().iter().all(u8::is_ascii_hexdigit),
            "Invalid key verifier"
        );
        self.grant.validate()?;
        if let Some(limits) = self.limits {
            limits.validate()?;
        }
        anyhow::ensure!(
            self.expires_at.is_none_or(|v| v <= 253402300799),
            "Invalid key expiry"
        );
        let mut bytes = [0; 32];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&self.verifier[i * 2..i * 2 + 2], 16).unwrap();
        }
        Ok(bytes)
    }
    pub fn metadata(&self) -> Value {
        json!({"id":self.id,"name":self.name,"grant":self.grant,"expiresAt":self.expires_at,"createdAt":self.created_at,"enabled":self.enabled,"limits":self.limits})
    }
}
/// Secret is returned only by creation, not recoverable from a registry snapshot.
pub struct KeyCreation {
    pub record: KeyRecord,
    pub secret: String,
}
impl fmt::Debug for KeyCreation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyCreation")
            .field("id", &self.record.id)
            .finish_non_exhaustive()
    }
}
pub fn create_key(
    name: String,
    grant: WorkspaceGrant,
    expires_at: Option<u64>,
) -> anyhow::Result<KeyCreation> {
    let mut random = [0; 32];
    SystemRandom::new()
        .fill(&mut random)
        .map_err(|_| anyhow::anyhow!("Key generation failed"))?;
    let id = uuid::Uuid::new_v4().to_string();
    let secret = format!("ls1.{id}.{}", URL_SAFE_NO_PAD.encode(random));
    let verifier = Sha256::digest(secret.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let record = KeyRecord {
        id,
        name,
        verifier,
        grant,
        expires_at,
        created_at: unix_time(),
        enabled: true,
        limits: None,
    };
    record.validate()?;
    anyhow::ensure!(
        expires_at.is_none_or(|expiry| expiry > unix_time()),
        "Key expiry must be in the future"
    );
    Ok(KeyCreation { record, secret })
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApiConfig {
    pub revision: u64,
    pub enabled: bool,
    pub auth_required: bool,
    pub global_limits: Limits,
    pub key_limits: Limits,
    pub anonymous_limits: Limits,
    pub anonymous_grant: WorkspaceGrant,
    pub allowed_origins: Vec<String>,
    pub keys: Vec<KeyRecord>,
}
impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            revision: 0,
            enabled: false,
            auth_required: true,
            global_limits: Limits {
                per_second: 30,
                per_minute: 600,
                concurrent: 16,
            },
            key_limits: Limits {
                per_second: 10,
                per_minute: 300,
                concurrent: 4,
            },
            anonymous_limits: Limits {
                per_second: 5,
                per_minute: 60,
                concurrent: 2,
            },
            anonymous_grant: WorkspaceGrant {
                scopes: vec![Scope::Service, Scope::Workspaces, Scope::Files],
                workspaces: vec!["*".into()],
            },
            allowed_origins: vec![],
            keys: vec![],
        }
    }
}
impl fmt::Debug for ApiConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApiConfig")
            .field("revision", &self.revision)
            .field("enabled", &self.enabled)
            .field("key_count", &self.keys.len())
            .finish_non_exhaustive()
    }
}
impl ApiConfig {
    fn validate(&self) -> anyhow::Result<()> {
        self.global_limits.validate()?;
        self.key_limits.validate()?;
        self.anonymous_limits.validate()?;
        self.anonymous_grant.validate()?;
        anyhow::ensure!(
            !self.anonymous_grant.scopes.contains(&Scope::RequestsManage)
                && !self.anonymous_grant.scopes.contains(&Scope::KeysManage)
                && !self.anonymous_grant.scopes.contains(&Scope::Requests)
                && !self.anonymous_grant.scopes.contains(&Scope::Upload)
                && !self.anonymous_grant.scopes.iter().any(|scope| matches!(
                    scope,
                    Scope::NativeTasksRead
                        | Scope::NativeTasksControl
                        | Scope::Manage
                        | Scope::DevicesRead
                        | Scope::DevicesScan
                        | Scope::TransfersRead
                        | Scope::TransfersSend
                        | Scope::TransfersControl
                        | Scope::CacheRead
                        | Scope::CacheClean
                        | Scope::SettingsRead
                        | Scope::SettingsWrite
                )),
            "Anonymous audit, upload or management access is not allowed"
        );
        anyhow::ensure!(
            self.keys.len() <= 128
                && self
                    .keys
                    .iter()
                    .map(|key| &key.id)
                    .collect::<HashSet<_>>()
                    .len()
                    == self.keys.len(),
            "Invalid key set"
        );
        for key in &self.keys {
            key.validate()?;
        }
        anyhow::ensure!(self.allowed_origins.len() <= 16, "Too many allowed origins");
        for origin in &self.allowed_origins {
            let parsed = reqwest::Url::parse(origin)
                .map_err(|_| anyhow::anyhow!("Invalid allowed origin"))?;
            anyhow::ensure!(
                origin.len() <= 512
                    && ["http", "https"].contains(&parsed.scheme())
                    && parsed.origin().ascii_serialization() == *origin,
                "Invalid allowed origin"
            );
        }
        Ok(())
    }
}
fn parse_configuration(value: &str) -> anyhow::Result<ApiConfig> {
    anyhow::ensure!(value.len() <= 512 * 1024, "API configuration too large");
    let config: ApiConfig =
        serde_json::from_str(value).map_err(|_| anyhow::anyhow!("Invalid API configuration"))?;
    config.validate()?;
    Ok(config)
}

/// Validate persistence candidates even while the listener is stopped.
/// Errors are deliberately independent of untrusted input values.
pub fn validate_configuration(value: &str) -> anyhow::Result<()> {
    parse_configuration(value).map(|_| ())
}

#[derive(Default)]
struct Window {
    second: u64,
    minute: u64,
    seconds_used: u32,
    minutes_used: u32,
    active: u32,
    last: u64,
}
impl Window {
    fn advance(&mut self, time: u64) {
        if self.second != time {
            self.second = time;
            self.seconds_used = 0;
        }
        if self.minute != time / 60 {
            self.minute = time / 60;
            self.minutes_used = 0;
        }
    }
    fn problem(&self, limits: Limits, time: u64) -> Option<(&'static str, u64)> {
        if limits.per_minute != 0 && self.minutes_used >= limits.per_minute {
            Some(("minute", 60 - time % 60))
        } else if limits.per_second != 0 && self.seconds_used >= limits.per_second {
            Some(("second", 1))
        } else if limits.concurrent != 0 && self.active >= limits.concurrent {
            Some(("concurrent", 1))
        } else {
            None
        }
    }
    fn consume(&mut self, time: u64) {
        self.seconds_used = self.seconds_used.saturating_add(1);
        self.minutes_used = self.minutes_used.saturating_add(1);
        self.active = self.active.saturating_add(1);
        self.last = time;
    }
}
struct Actor {
    window: Arc<Mutex<Window>>,
    cancel: CancellationToken,
}
impl Actor {
    // Cancellation epochs change independently of quota accounting. Old worker
    // holds keep consuming concurrency until their final descriptor closes.
    fn renew(&self) -> Self {
        Self {
            window: self.window.clone(),
            cancel: CancellationToken::new(),
        }
    }
    fn new() -> Self {
        Self {
            window: Arc::new(Mutex::new(Window::default())),
            cancel: CancellationToken::new(),
        }
    }
}
struct RuntimeKey {
    record: KeyRecord,
    digest: [u8; 32],
    actor: Arc<Actor>,
}
struct State {
    config: ApiConfig,
    keys: HashMap<String, RuntimeKey>,
    anonymous: HashMap<String, Arc<Actor>>,
    global: Window,
    history: super::request_history::History,
}
pub(crate) struct Registry {
    pub management_available: AtomicBool,
    state: Mutex<State>,
    started: Instant,
    port: AtomicU16,
    pub(super) instance_id: String,
}
pub(crate) struct Lease {
    registry: Arc<Registry>,
    actor: Arc<Actor>,
    quota: Arc<QuotaHold>,
    pub principal: Option<String>,
    pub grant: WorkspaceGrant,
    pub expires: Option<u64>,
    pub cancel: CancellationToken,
    pub id: String,
    pub operation: &'static str,
    pub method: &'static str,
    started: Instant,
    pub status: u16,
    pub error: Option<&'static str>,
    pub reason: Option<String>,
    pub bytes: u64,
    pub outcome: &'static str,
    pub remaining_second: u32,
    pub remaining_minute: u32,
}
struct QuotaHold {
    registry: Arc<Registry>,
    actor: Arc<Actor>,
}
impl Drop for QuotaHold {
    fn drop(&mut self) {
        let mut state = self.registry.state.lock().unwrap();
        state.global.active = state.global.active.saturating_sub(1);
        let mut actor = self.actor.window.lock().unwrap();
        actor.active = actor.active.saturating_sub(1);
    }
}
#[derive(Clone)]
pub(crate) struct UploadAuthority {
    registry: Arc<Registry>,
    actor: Arc<Actor>,
    _quota: Arc<QuotaHold>,
    pub cancel: CancellationToken,
    pub expires: Option<u64>,
}
impl UploadAuthority {
    pub fn claim_management<T>(
        &self,
        action: impl FnOnce() -> Result<T, hyper::StatusCode>,
    ) -> Result<T, hyper::StatusCode> {
        let state = self.registry.state.lock().unwrap();
        if !self.registry.management_available.load(Ordering::Acquire)
            || !state.config.enabled
            || !self.valid()
            || !state
                .keys
                .values()
                .any(|key| Arc::ptr_eq(&key.actor, &self.actor))
        {
            return Err(hyper::StatusCode::UNAUTHORIZED);
        }
        action()
    }
    pub fn valid(&self) -> bool {
        !self.cancel.is_cancelled() && self.expires.is_none_or(|expiry| expiry > unix_time())
    }
    /// Filesystem commit and key revocation share the registry lock. Called only
    /// from a blocking writer, never across async body reads or full-file I/O.
    pub fn publish<T>(
        &self,
        action: impl FnOnce() -> Result<T, hyper::StatusCode>,
    ) -> Result<T, hyper::StatusCode> {
        let state = self.registry.state.lock().unwrap();
        if !state.config.enabled
            || !self.valid()
            || !state
                .keys
                .values()
                .any(|key| Arc::ptr_eq(&key.actor, &self.actor))
        {
            return Err(hyper::StatusCode::UNAUTHORIZED);
        }
        action()
    }
}
impl Lease {
    pub fn transfer_authority(&self, scope: Scope) -> Option<UploadAuthority> {
        if self.principal.is_none()
            || !self.grant.scopes.contains(&scope)
            || !self.grant.workspaces.iter().any(|id| id == "*")
        {
            return None;
        }
        Some(UploadAuthority {
            registry: self.registry.clone(),
            actor: self.actor.clone(),
            _quota: self.quota.clone(),
            cancel: self.cancel.clone(),
            expires: self.expires,
        })
    }
    pub fn management_authority(&self) -> Option<UploadAuthority> {
        if self.principal.is_none() || !self.grant.scopes.contains(&Scope::Manage) {
            return None;
        }
        Some(UploadAuthority {
            registry: self.registry.clone(),
            actor: self.actor.clone(),
            _quota: self.quota.clone(),
            cancel: self.cancel.clone(),
            expires: self.expires,
        })
    }
    pub fn upload_authority(&self) -> Option<UploadAuthority> {
        if self.principal.is_none() || !self.grant.scopes.contains(&Scope::Upload) {
            return None;
        }
        Some(UploadAuthority {
            registry: self.registry.clone(),
            actor: self.actor.clone(),
            _quota: self.quota.clone(),
            cancel: self.cancel.clone(),
            expires: self.expires,
        })
    }
}

pub(crate) struct Denied {
    pub code: &'static str,
    pub status: u16,
    pub retry: Option<u64>,
    pub reason: Option<String>,
    pub remaining: Option<(u32, u32)>,
}
impl Denied {
    pub fn new(status: u16, code: &'static str) -> Self {
        Self {
            code,
            status,
            retry: None,
            reason: None,
            remaining: None,
        }
    }
}
pub(crate) fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
impl Registry {
    pub fn new() -> Self {
        Self {
            management_available: AtomicBool::new(false),
            state: Mutex::new(State {
                config: ApiConfig::default(),
                keys: HashMap::new(),
                anonymous: HashMap::new(),
                global: Window::default(),
                history: super::request_history::History::default(),
            }),
            started: Instant::now(),
            port: AtomicU16::new(0),
            instance_id: uuid::Uuid::new_v4().to_string(),
        }
    }
    pub fn set_management_available(&self, available: bool) {
        let _state = self.state.lock().unwrap();
        self.management_available
            .store(available, Ordering::Release);
    }
    pub fn set_port(&self, port: u16) {
        self.port.store(port, Ordering::Release);
    }
    pub fn configure(&self, value: &str) -> anyhow::Result<String> {
        let config = parse_configuration(value)?;
        let mut state = self.state.lock().unwrap();
        anyhow::ensure!(
            config.revision > state.config.revision,
            "Stale API configuration"
        );
        let mut keys = HashMap::new();
        for record in &config.keys {
            let actor = state
                .keys
                .get(&record.id)
                .filter(|old| {
                    old.record.verifier == record.verifier
                        && old.record.grant == record.grant
                        && old.record.expires_at == record.expires_at
                        && !old.actor.cancel.is_cancelled()
                        && config.enabled
                        && record.enabled
                        && old.record.enabled
                })
                .map(|old| old.actor.clone())
                .unwrap_or_else(|| {
                    state
                        .keys
                        .get(&record.id)
                        .filter(|old| old.record.verifier == record.verifier)
                        .map(|old| Arc::new(old.actor.renew()))
                        .unwrap_or_else(|| Arc::new(Actor::new()))
                });
            keys.insert(
                record.id.clone(),
                RuntimeKey {
                    record: record.clone(),
                    digest: record.validate()?,
                    actor,
                },
            );
        }
        for (id, old) in &state.keys {
            if !config.enabled
                || !keys
                    .get(id)
                    .is_some_and(|new| Arc::ptr_eq(&new.actor, &old.actor))
            {
                old.actor.cancel.cancel();
            }
        }
        if !config.enabled
            || config.auth_required != state.config.auth_required
            || config.anonymous_grant != state.config.anonymous_grant
            || config.allowed_origins != state.config.allowed_origins
        {
            for actor in state.anonymous.values_mut() {
                actor.cancel.cancel();
                *actor = Arc::new(actor.renew());
            }
        }
        // Origin policy reductions also invalidate already admitted key streams.
        if config.allowed_origins != state.config.allowed_origins {
            for key in keys.values_mut() {
                key.actor.cancel.cancel();
                key.actor = Arc::new(key.actor.renew());
            }
        }
        state.keys = keys;
        state.config = config;
        Ok(json!({"revision":state.config.revision,"enabled":state.config.enabled,"keys":state.keys.len()}).to_string())
    }
    pub fn snapshot(&self) -> Value {
        let state = self.state.lock().unwrap();
        json!({"instanceId":self.instance_id,"revision":state.config.revision,"enabled":state.config.enabled,"authRequired":state.config.auth_required,"port":self.port.load(Ordering::Acquire),"globalLimits":state.config.global_limits,"keyLimits":state.config.key_limits,"anonymousLimits":state.config.anonymous_limits,"anonymousGrant":state.config.anonymous_grant,"allowedOrigins":state.config.allowed_origins,"keys":state.config.keys.iter().map(KeyRecord::metadata).collect::<Vec<_>>(),"activeResponses":state.global.active,"recordCount":state.history.len()})
    }
    pub fn enabled(&self) -> bool {
        self.state.lock().unwrap().config.enabled
    }
    pub fn origins(&self) -> Vec<String> {
        self.state.lock().unwrap().config.allowed_origins.clone()
    }
    pub fn records(&self, after: u64, limit: usize) -> Value {
        self.state
            .lock()
            .unwrap()
            .history
            .records(&self.instance_id, after, limit)
    }
    fn record(state: &mut State, value: Value) {
        state.history.record(value, unix_time());
    }
    pub(super) fn clear_records(
        &self,
        lease: &Lease,
        input: &super::request_history::ClearRequest,
    ) -> Result<Value, Denied> {
        let mut state = self.state.lock().unwrap();
        let Some(principal) = lease.principal.as_ref() else {
            return Err(Denied::new(403, "insufficient_scope"));
        };
        if !lease.grant.scopes.contains(&Scope::RequestsManage)
            || !lease.grant.workspaces.iter().any(|id| id == "*")
        {
            return Err(Denied::new(403, "insufficient_scope"));
        }
        // Same lock as key/configuration revocation. Body parsing may await, but
        // a revoked or expired lease cannot clear history after that await.
        if !state.config.enabled
            || lease.cancel.is_cancelled()
            || lease.expires.is_some_and(|at| at <= unix_time())
            || !state
                .keys
                .get(principal)
                .is_some_and(|key| key.record.enabled && Arc::ptr_eq(&key.actor, &lease.actor))
        {
            return Err(Denied::new(401, "revoked"));
        }
        state
            .history
            .clear(&self.instance_id, input, &lease.id, principal, unix_time())
            .map_err(|code| {
                Denied::new(
                    if code == "invalid_watermark" {
                        400
                    } else {
                        409
                    },
                    code,
                )
            })
    }
    pub fn rejection(&self, id: &str, operation: &str, method: &str, denied: &Denied) {
        Self::record(
            &mut self.state.lock().unwrap(),
            json!({"requestId":id,"operation":operation,"method":method,"principal":null,"status":denied.status,"outcome":denied.code,"error":denied.code,"reason":denied.reason,"bytes":0,"elapsedMs":0}),
        );
    }
    pub fn admit(
        self: &Arc<Self>,
        headers: &HeaderMap,
        peer: String,
        id: String,
        operation: &'static str,
        method: &'static str,
        preflight: bool,
    ) -> Result<(Lease, Option<Denied>), Denied> {
        let mut state = self.state.lock().unwrap();
        if !state.config.enabled {
            return Err(Denied::new(404, "api_disabled"));
        }
        let time = self.started.elapsed().as_secs();
        let mut auth_error = None;
        let parsed = if preflight { None } else { token(headers) };
        let key = parsed.as_ref().and_then(|(id, token)| {
            state.keys.get(*id).filter(|key| {
                bool::from(
                    Sha256::digest(token.as_bytes())
                        .as_slice()
                        .ct_eq(&key.digest),
                ) && key
                    .record
                    .expires_at
                    .is_none_or(|expiry| expiry > unix_time())
                    && !key.actor.cancel.is_cancelled()
            })
        });
        let (actor, principal, grant, expires, limits) = if let Some(key) = key {
            if !key.record.enabled {
                return Err(Denied::new(403, "key_paused"));
            }
            (
                key.actor.clone(),
                Some(key.record.id.clone()),
                key.record.grant.clone(),
                key.record.expires_at,
                key.record.limits.unwrap_or(state.config.key_limits),
            )
        } else {
            if !preflight
                && (headers.contains_key(header::AUTHORIZATION) || state.config.auth_required)
            {
                auth_error = Some(Denied::new(401, "unauthorized"));
            }
            state.anonymous.retain(|_, actor| {
                let w = actor.window.lock().unwrap();
                w.active > 0 || time.saturating_sub(w.last) < 60
            });
            if !state.anonymous.contains_key(&peer) && state.anonymous.len() >= 256 {
                return Err(Denied {
                    status: 429,
                    code: "rate_limited",
                    retry: Some(60),
                    reason: Some("anonymous.capacity".into()),
                    remaining: None,
                });
            }
            let actor = state
                .anonymous
                .entry(peer)
                .or_insert_with(|| Arc::new(Actor::new()))
                .clone();
            (
                actor,
                None,
                state.config.anonymous_grant.clone(),
                None,
                state.config.anonymous_limits,
            )
        };
        if state.global.active >= 64 {
            return Err(Denied {
                status: 429,
                code: "rate_limited",
                retry: Some(1),
                reason: Some("server.concurrent".into()),
                remaining: None,
            });
        }
        state.global.advance(time);
        let mut window = actor.window.lock().unwrap();
        window.advance(time);
        let global_problem = state
            .global
            .problem(state.config.global_limits, time)
            .map(|(name, wait)| (format!("global.{name}"), wait));
        let actor_problem = window.problem(limits, time).map(|(name, wait)| {
            (
                format!(
                    "{}.{name}",
                    if principal.is_some() {
                        "key"
                    } else {
                        "anonymous"
                    }
                ),
                wait,
            )
        });
        if let Some((reason, wait)) = global_problem
            .into_iter()
            .chain(actor_problem)
            .max_by_key(|(_, wait)| *wait)
        {
            return Err(Denied {
                status: 429,
                code: "rate_limited",
                retry: Some(wait),
                reason: Some(reason),
                remaining: Some((
                    remaining(
                        state.config.global_limits.per_second,
                        state.global.seconds_used,
                    )
                    .min(remaining(limits.per_second, window.seconds_used)),
                    remaining(
                        state.config.global_limits.per_minute,
                        state.global.minutes_used,
                    )
                    .min(remaining(limits.per_minute, window.minutes_used)),
                )),
            });
        }
        state.global.consume(time);
        window.consume(time);
        let remaining_second = remaining(
            state.config.global_limits.per_second,
            state.global.seconds_used,
        )
        .min(remaining(limits.per_second, window.seconds_used));
        let remaining_minute = remaining(
            state.config.global_limits.per_minute,
            state.global.minutes_used,
        )
        .min(remaining(limits.per_minute, window.minutes_used));
        drop(window);
        Ok((
            Lease {
                registry: self.clone(),
                cancel: actor.cancel.clone(),
                quota: Arc::new(QuotaHold {
                    registry: self.clone(),
                    actor: actor.clone(),
                }),
                actor,
                principal,
                grant,
                expires,
                id,
                operation,
                method,
                started: Instant::now(),
                status: 500,
                error: None,
                reason: None,
                bytes: 0,
                outcome: "interrupted",
                remaining_second,
                remaining_minute,
            },
            auth_error,
        ))
    }
}
// Unlimited dimensions expose the u32 ceiling, while finite layers still bound
// remaining credits. This never controls the independent 64-response hard cap.
fn remaining(limit: u32, used: u32) -> u32 {
    if limit == 0 {
        u32::MAX
    } else {
        limit.saturating_sub(used)
    }
}
fn token(headers: &HeaderMap) -> Option<(&str, &str)> {
    if headers.get_all(header::AUTHORIZATION).iter().count() != 1 {
        return None;
    }
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") || token.len() > 128 {
        return None;
    }
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3
        || parts[0] != "ls1"
        || parts[1].len() != 36
        || parts[2].len() != 43
        || !parts[2]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return None;
    }
    Some((parts[1], token))
}
impl Drop for Lease {
    fn drop(&mut self) {
        let mut state = self.registry.state.lock().unwrap();
        let outcome = if self.cancel.is_cancelled() {
            "revoked"
        } else if self.expires.is_some_and(|expiry| expiry <= unix_time()) {
            "expired"
        } else {
            self.outcome
        };
        Registry::record(
            &mut state,
            json!({"requestId":self.id,"operation":self.operation,"method":self.method,"principal":self.principal,"status":self.status,"outcome":outcome,"error":self.error,"reason":self.reason,"bytes":self.bytes,"elapsedMs":self.started.elapsed().as_millis().min(u64::MAX as u128) as u64}),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn upload_fixture() -> (Arc<Registry>, ApiConfig, Lease) {
        let registry = Arc::new(Registry::new());
        let key = create_key(
            "upload".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Upload],
                workspaces: vec!["*".into()],
            },
            None,
        )
        .unwrap();
        let config = ApiConfig {
            revision: 1,
            enabled: true,
            keys: vec![key.record],
            ..ApiConfig::default()
        };
        registry
            .configure(&serde_json::to_string(&config).unwrap())
            .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            format!("Bearer {}", key.secret).parse().unwrap(),
        );
        let (lease, error) = registry
            .admit(
                &headers,
                "127.0.0.1".into(),
                uuid::Uuid::new_v4().to_string(),
                "uploadFile",
                "POST",
                false,
            )
            .unwrap_or_else(|_| panic!("admission failed"));
        assert!(error.is_none());
        (registry, config, lease)
    }
    #[test]
    fn anonymous_upload_scope_is_rejected_without_changing_defaults() {
        let mut config = ApiConfig::default();
        assert!(!config.anonymous_grant.scopes.contains(&Scope::Upload));
        config.anonymous_grant.scopes.push(Scope::Upload);
        assert!(config.validate().is_err());
    }
    #[test]
    fn detached_upload_worker_retains_concurrent_quota_after_audit_lease_drop() {
        let (registry, _, lease) = upload_fixture();
        let authority = lease.upload_authority().unwrap();
        assert_eq!(registry.snapshot()["activeResponses"], 1);
        drop(lease);
        assert_eq!(registry.snapshot()["activeResponses"], 1);
        drop(authority);
        assert_eq!(registry.snapshot()["activeResponses"], 0);
    }
    #[test]
    fn revoked_or_expired_upload_authority_never_enters_publication() {
        let (registry, mut config, lease) = upload_fixture();
        let mut authority = lease.upload_authority().unwrap();
        authority.expires = Some(0);
        assert_eq!(
            authority.publish(|| Ok(())),
            Err(hyper::StatusCode::UNAUTHORIZED)
        );
        authority.expires = None;
        config.revision = 2;
        config.keys.clear();
        registry
            .configure(&serde_json::to_string(&config).unwrap())
            .unwrap();
        assert_eq!(
            authority.publish(|| panic!("revoked publication")),
            Err::<(), _>(hyper::StatusCode::UNAUTHORIZED)
        );
    }
    #[test]
    fn key_revocation_waits_for_atomic_publication_commit() {
        let (registry, mut config, lease) = upload_fixture();
        let authority = lease.upload_authority().unwrap();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (finish_tx, finish_rx) = std::sync::mpsc::channel();
        let publishing = std::thread::spawn(move || {
            authority.publish(|| {
                entered_tx.send(()).unwrap();
                finish_rx.recv().unwrap();
                Ok(())
            })
        });
        entered_rx.recv().unwrap();
        config.revision = 2;
        config.enabled = false;
        let registry_copy = registry.clone();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let revoking = std::thread::spawn(move || {
            registry_copy
                .configure(&serde_json::to_string(&config).unwrap())
                .unwrap();
            done_tx.send(()).unwrap();
        });
        assert!(
            done_rx
                .recv_timeout(std::time::Duration::from_millis(30))
                .is_err()
        );
        finish_tx.send(()).unwrap();
        assert!(publishing.join().unwrap().is_ok());
        done_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        revoking.join().unwrap();
        assert!(lease.cancel.is_cancelled());
    }
    #[test]
    fn windows_are_atomic_fixed_periods_and_bounded() {
        let limits = Limits {
            per_second: 2,
            per_minute: 3,
            concurrent: 4,
        };
        let mut w = Window::default();
        w.advance(0);
        w.consume(0);
        w.consume(0);
        assert_eq!(w.problem(limits, 0), Some(("second", 1)));
        w.advance(1);
        w.consume(1);
        assert_eq!(w.problem(limits, 1), Some(("minute", 59)));
        w.advance(60);
        assert_eq!(w.problem(limits, 60), None);
    }
    #[test]
    fn debug_and_metadata_never_recover_secrets() {
        let key = create_key(
            "Client".into(),
            WorkspaceGrant {
                scopes: vec![Scope::Service],
                workspaces: vec![],
            },
            None,
        )
        .unwrap();
        assert!(!format!("{key:?}").contains(&key.secret));
        assert!(!format!("{:?}", key.record).contains(&key.record.verifier));
        assert!(
            !key.record
                .metadata()
                .to_string()
                .contains(&key.record.verifier)
        );
    }
}

#[cfg(test)]
#[path = "policy_lifecycle_tests.rs"]
mod lifecycle_tests;
