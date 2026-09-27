//! Workspace-only password verification and bounded, revocable browser grants.
//! Plaintext passwords never enter configuration, responses or diagnostics.
use super::common::error::AppError;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hyper::{HeaderMap, StatusCode, header};
use lru::LruCache;
use ring::{
    digest, pbkdf2,
    rand::{SecureRandom, SystemRandom},
};
use std::{
    collections::HashMap,
    num::{NonZeroU32, NonZeroUsize},
    sync::Mutex,
    time::{Duration, Instant},
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

const ITERATIONS: u32 = 600_000;
pub(super) const SESSION_SECONDS: u64 = 3600;
static PASSWORD_WORKERS: Semaphore = Semaphore::const_new(2);

fn random_bytes<const N: usize>() -> anyhow::Result<[u8; N]> {
    let mut bytes = [0; N];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("Random source unavailable"))?;
    Ok(bytes)
}
pub(super) fn parse_verifier(value: &str) -> anyhow::Result<([u8; 16], [u8; 32])> {
    let fields: Vec<_> = value.split('$').collect();
    anyhow::ensure!(
        fields.len() == 4 && fields[0] == "pbkdf2-sha256" && fields[1] == "600000",
        "Invalid password verifier"
    );
    let salt: [u8; 16] = URL_SAFE_NO_PAD
        .decode(fields[2])
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| anyhow::anyhow!("Invalid password verifier"))?;
    let hash: [u8; 32] = URL_SAFE_NO_PAD
        .decode(fields[3])
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| anyhow::anyhow!("Invalid password verifier"))?;
    anyhow::ensure!(
        URL_SAFE_NO_PAD.encode(salt) == fields[2] && URL_SAFE_NO_PAD.encode(hash) == fields[3],
        "Invalid password verifier"
    );
    Ok((salt, hash))
}
/// Local app operation. PBKDF2 executes on a bounded blocking worker.
pub async fn hash_password(password: String) -> anyhow::Result<String> {
    anyhow::ensure!(
        (4..=128).contains(&password.chars().count()) && password.len() <= 1024,
        "Password must contain 4 to 128 characters"
    );
    let permit = PASSWORD_WORKERS.acquire().await?;
    // The static semaphore permit must outlive a dropped caller while the worker keeps running.
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let salt = random_bytes::<16>()?;
        let mut hash = [0; 32];
        pbkdf2::derive(
            pbkdf2::PBKDF2_HMAC_SHA256,
            NonZeroU32::new(ITERATIONS).unwrap(),
            &salt,
            password.as_bytes(),
            &mut hash,
        );
        Ok(format!(
            "pbkdf2-sha256$600000${}${}",
            URL_SAFE_NO_PAD.encode(salt),
            URL_SAFE_NO_PAD.encode(hash)
        ))
    })
    .await?
}

#[derive(Clone)]
pub(super) struct Grant {
    pub cancel: CancellationToken,
    pub expires: Instant,
}
pub(super) struct Access {
    verifier: Option<String>,
    grants: Mutex<LruCache<String, Grant>>,
}
impl Access {
    pub fn new(verifier: Option<String>) -> Self {
        Self {
            verifier,
            grants: Mutex::new(LruCache::new(NonZeroUsize::new(64).unwrap())),
        }
    }
    pub fn protected(&self) -> bool {
        self.verifier.is_some()
    }
    pub async fn verify(&self, password: String) -> Result<bool, AppError> {
        if password.len() > 1024 {
            return Err(AppError::Status(StatusCode::BAD_REQUEST));
        }
        let Some(verifier) = self.verifier.as_ref() else {
            return Ok(true);
        };
        let (salt, expected) = parse_verifier(verifier)
            .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
        let permit = PASSWORD_WORKERS
            .try_acquire()
            .map_err(|_| AppError::Status(StatusCode::TOO_MANY_REQUESTS))?;
        // The global semaphore is static: the permit can safely be moved into the worker.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            pbkdf2::verify(
                pbkdf2::PBKDF2_HMAC_SHA256,
                NonZeroU32::new(ITERATIONS).unwrap(),
                &salt,
                password.as_bytes(),
                &expected,
            )
            .is_ok()
        })
        .await
        .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))
    }
    pub fn issue(&self) -> Result<String, AppError> {
        let token = URL_SAFE_NO_PAD.encode(
            random_bytes::<32>()
                .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?,
        );
        let mut grants = self.grants.lock().unwrap();
        let expired: Vec<_> = grants
            .iter()
            .filter(|(_, v)| v.expires <= Instant::now())
            .map(|(k, _)| k.clone())
            .collect();
        for key in expired {
            if let Some(g) = grants.pop(&key) {
                g.cancel.cancel();
            }
        }
        let grant = Grant {
            cancel: CancellationToken::new(),
            expires: Instant::now() + Duration::from_secs(SESSION_SECONDS),
        };
        if let Some((_, old)) = grants.push(token_key(&token), grant) {
            old.cancel.cancel();
        }
        Ok(token)
    }
    pub fn authorize(&self, headers: &HeaderMap, id: &str) -> Result<Option<Grant>, AppError> {
        if !self.protected() {
            return Ok(None);
        }
        let token = cookie_token(headers, id).ok_or(AppError::Status(StatusCode::UNAUTHORIZED))?;
        let mut grants = self.grants.lock().unwrap();
        let grant = grants
            .get(&token_key(token))
            .cloned()
            .ok_or(AppError::Status(StatusCode::UNAUTHORIZED))?;
        if grant.cancel.is_cancelled() || grant.expires <= Instant::now() {
            return Err(AppError::Status(StatusCode::UNAUTHORIZED));
        }
        Ok(Some(grant))
    }
    pub fn logout(&self, headers: &HeaderMap, id: &str) {
        if let Some(token) = cookie_token(headers, id) {
            if let Some(grant) = self.grants.lock().unwrap().pop(&token_key(token)) {
                grant.cancel.cancel();
            }
        }
    }
}
fn token_key(value: &str) -> String {
    URL_SAFE_NO_PAD.encode(digest::digest(&digest::SHA256, value.as_bytes()).as_ref())
}
pub(super) fn cookie_name(id: &str) -> String {
    format!("lsw_{}", id.replace('-', ""))
}
fn cookie_token<'a>(headers: &'a HeaderMap, id: &str) -> Option<&'a str> {
    let name = cookie_name(id);
    let mut found = None;
    for value in headers.get_all(header::COOKIE) {
        for item in value.to_str().ok()?.split(';') {
            let Some((key, value)) = item.trim().split_once('=') else {
                continue;
            };
            if key == name {
                if found.is_some() || value.len() != 43 {
                    return None;
                }
                found = Some(value);
            }
        }
    }
    found
}

pub(super) struct LoginBudget {
    peers: HashMap<String, (Instant, u32)>,
    global: (Instant, u32),
}
impl LoginBudget {
    pub fn new() -> Self {
        Self {
            peers: HashMap::new(),
            global: (Instant::now(), 0),
        }
    }
    pub fn consume(&mut self, key: String) -> Result<(), u64> {
        let now = Instant::now();
        self.peers
            .retain(|_, (start, _)| now.duration_since(*start) < Duration::from_secs(60));
        if now.duration_since(self.global.0) >= Duration::from_secs(60) {
            self.global = (now, 0);
        }
        if self.global.1 >= 30 {
            return Err(60 - now.duration_since(self.global.0).as_secs());
        }
        if self.peers.len() >= 1024 && !self.peers.contains_key(&key) {
            return Err(60);
        }
        let peer = self.peers.entry(key).or_insert((now, 0));
        if peer.1 >= 5 {
            return Err(60 - now.duration_since(peer.0).as_secs());
        }
        peer.1 += 1;
        self.global.1 += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn salted_verifiers_have_fixed_work_factor_and_reject_malformed_input() {
        let a = hash_password("unicode-密码".into()).await.unwrap();
        let b = hash_password("unicode-密码".into()).await.unwrap();
        assert_ne!(a, b);
        assert!(!a.contains("密码"));
        assert!(parse_verifier(&a).is_ok());
        for invalid in [
            a.replace("600000", "1"),
            format!("{a}extra"),
            "plaintext".into(),
        ] {
            assert!(parse_verifier(&invalid).is_err());
        }
        assert!(hash_password("123".into()).await.is_err());
    }
    #[test]
    fn expired_evicted_and_duplicate_cookie_grants_fail_closed() {
        let access = Access::new(Some("not used by this test".into()));
        let token = access.issue().unwrap();
        let id = "test";
        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            format!("{}={token}", cookie_name(id)).parse().unwrap(),
        );
        assert!(access.authorize(&headers, id).is_ok());
        access
            .grants
            .lock()
            .unwrap()
            .get_mut(&token_key(&token))
            .unwrap()
            .expires = Instant::now() - Duration::from_secs(1);
        assert!(access.authorize(&headers, id).is_err());
        let first = access.issue().unwrap();
        let first_grant = access
            .grants
            .lock()
            .unwrap()
            .get(&token_key(&first))
            .unwrap()
            .clone();
        for _ in 0..64 {
            access.issue().unwrap();
        }
        assert!(first_grant.cancel.is_cancelled());
        let live = access.issue().unwrap();
        headers.insert(
            header::COOKIE,
            format!("{0}={live}; {0}={live}", cookie_name(id))
                .parse()
                .unwrap(),
        );
        assert!(access.authorize(&headers, id).is_err());
    }
    #[test]
    fn global_budget_limits_rotating_sources_without_eviction_bypass() {
        let mut budget = LoginBudget::new();
        for i in 0..30 {
            assert!(budget.consume(format!("peer-{i}")).is_ok());
        }
        assert!(budget.consume("new-peer".into()).is_err());
        budget.global.0 -= Duration::from_secs(61);
        assert!(budget.consume("new-peer".into()).is_ok());
    }
}
