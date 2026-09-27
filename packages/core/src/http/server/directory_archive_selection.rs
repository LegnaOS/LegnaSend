//! Metadata-only, authority-bound selections for short workspace archive URLs.
//! The router must authenticate each request and validate backend IDs before
//! preparing; possession of a selection is never an authorization substitute.
use serde::Deserialize;
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

pub(super) const MAX_BODY: usize = 2 * 1024 * 1024;
pub(super) const MAX_IDS: usize = 20_000;
pub(super) const TTL: Duration = Duration::from_secs(120);
const MAX_TICKETS: usize = 64;
const MAX_PER_CALLER: usize = 4;
const MAX_METADATA: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Error {
    Invalid,
    TooLarge,
    Busy,
    Gone,
    Forbidden,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Selection {
    pub(super) path: String,
    pub(super) ids: Vec<String>,
}
impl Selection {
    pub(super) fn parse(body: &[u8]) -> Result<Self, Error> {
        if body.len() > MAX_BODY {
            return Err(Error::TooLarge);
        }
        let selection: Self = serde_json::from_slice(body).map_err(|_| Error::Invalid)?;
        selection.validate()?;
        Ok(selection)
    }
    fn validate(&self) -> Result<(), Error> {
        if self.ids.is_empty() || self.ids.len() > MAX_IDS {
            return Err(Error::TooLarge);
        }
        if self.path.len() > 4096 || self.path.contains('\0') {
            return Err(Error::Invalid);
        }
        let mut unique = HashSet::with_capacity(self.ids.len());
        for id in &self.ids {
            if id.is_empty()
                || id.len() > 4096
                || id.chars().any(char::is_control)
                || !unique.insert(id)
            {
                return Err(Error::Invalid);
            }
        }
        Ok(())
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Caller {
    Browser(String),
    Api,
}
#[derive(Clone)]
pub(super) struct Authority {
    pub(super) cancel: CancellationToken,
    pub(super) expires: Instant,
}
#[derive(Clone)]
pub(super) struct Context {
    pub(super) owner: String,
    pub(super) workspace: String,
    pub(super) generation: u64,
    pub(super) caller: Caller,
    pub(super) workspace_cancel: CancellationToken,
    pub(super) authority: Option<Authority>,
}
impl Context {
    fn live(&self, now: Instant) -> bool {
        !self.workspace_cancel.is_cancelled()
            && self
                .authority
                .as_ref()
                .is_none_or(|a| !a.cancel.is_cancelled() && a.expires > now)
    }
    fn matches(&self, current: &Self) -> bool {
        self.owner == current.owner
            && self.workspace == current.workspace
            && self.generation == current.generation
            && self.caller == current.caller
            && self.workspace_cancel == current.workspace_cancel
            && match (&self.authority, &current.authority) {
                (None, None) => true,
                (Some(a), Some(b)) => a.cancel == b.cancel,
                _ => false,
            }
    }
    fn same_caller(&self, current: &Self) -> bool {
        self.owner == current.owner
            && self.workspace == current.workspace
            && self.generation == current.generation
            && self.caller == current.caller
            && match &self.caller {
                Caller::Browser(_) => true,
                Caller::Api => match (&self.authority, &current.authority) {
                    (Some(a), Some(b)) => a.cancel == b.cancel,
                    _ => false,
                },
            }
    }
    fn valid(&self) -> bool {
        [self.owner.as_str(), self.workspace.as_str()]
            .iter()
            .all(|s| uuid::Uuid::parse_str(s).is_ok_and(|id| id.to_string() == *s))
            && match &self.caller {
                Caller::Browser(ip) => !ip.is_empty() && ip.len() <= 256,
                Caller::Api => self.authority.is_some(),
            }
    }
}
pub(super) struct Ticket {
    pub(super) id: String,
    pub(super) selection: Selection,
    context: Context,
    pub(super) expires: Instant,
    pub(super) cancel: CancellationToken,
    // Held until the last real plan/stream releases the metadata, not merely
    // until the HTTP waiter drops or its registry entry expires.
    _slot: Arc<OwnedSemaphorePermit>,
    _bytes: OwnedSemaphorePermit,
}
impl Ticket {
    fn live(&self, now: Instant) -> bool {
        self.expires > now && self.context.live(now) && !self.cancel.is_cancelled()
    }
    pub(super) fn remaining(&self, now: Instant) -> Duration {
        self.expires.saturating_duration_since(now)
    }
    pub(super) async fn ended(&self) {
        tokio::select! {biased;
            _ = self.cancel.cancelled() => {},
            _ = self.context.workspace_cancel.cancelled() => {},
            _ = async { if let Some(a)=&self.context.authority { tokio::select! { _=a.cancel.cancelled()=>{}, _=tokio::time::sleep_until(a.expires.into())=>{} } } else { std::future::pending::<()>().await; } } => {},
        }
    }
}
impl Drop for Ticket {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
struct Inner {
    controls: Mutex<HashMap<String, Weak<Ticket>>>,
    tickets: Mutex<HashMap<String, Arc<Ticket>>>,
    slots: Arc<Semaphore>,
    bytes: Arc<Semaphore>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        for ticket in self
            .controls
            .get_mut()
            .unwrap()
            .values()
            .filter_map(Weak::upgrade)
        {
            ticket.cancel.cancel();
        }
    }
}
#[derive(Clone)]
pub(super) struct Registry {
    inner: Arc<Inner>,
}
impl Registry {
    pub(super) fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                tickets: Mutex::new(HashMap::new()),
                controls: Mutex::new(HashMap::new()),
                slots: Arc::new(Semaphore::new(MAX_TICKETS)),
                bytes: Arc::new(Semaphore::new(MAX_METADATA)),
            }),
        }
    }
    fn sweep(tickets: &mut HashMap<String, Arc<Ticket>>, now: Instant) {
        tickets.retain(|_, ticket| {
            if ticket.live(now) {
                true
            } else {
                if !ticket.context.live(now) {
                    ticket.cancel.cancel();
                }
                false
            }
        });
    }
    pub(super) fn prepare(
        &self,
        context: Context,
        selection: Selection,
    ) -> Result<Arc<Ticket>, Error> {
        self.prepare_at(context, selection, Instant::now())
    }
    fn prepare_at(
        &self,
        context: Context,
        selection: Selection,
        now: Instant,
    ) -> Result<Arc<Ticket>, Error> {
        selection.validate()?;
        if !context.valid() {
            return Err(Error::Invalid);
        }
        if !context.live(now) {
            return Err(Error::Gone);
        }
        let bytes = std::mem::size_of::<Ticket>()
            + 128
            + context.owner.capacity()
            + context.workspace.capacity()
            + match &context.caller {
                Caller::Browser(s) => s.capacity(),
                Caller::Api => 0,
            }
            + selection.path.capacity()
            + selection.ids.capacity() * std::mem::size_of::<String>()
            + selection.ids.iter().map(String::capacity).sum::<usize>();
        let bytes = u32::try_from(bytes).map_err(|_| Error::TooLarge)?;
        if bytes as usize > MAX_METADATA {
            return Err(Error::TooLarge);
        }
        let mut tickets = self.inner.tickets.lock().unwrap();
        Self::sweep(&mut tickets, now);
        let mut controls = self.inner.controls.lock().unwrap();
        controls.retain(|_, ticket| ticket.strong_count() > 0);
        if controls
            .values()
            .filter_map(Weak::upgrade)
            .filter(|t| !t.cancel.is_cancelled() && t.context.same_caller(&context))
            .count()
            >= MAX_PER_CALLER
        {
            return Err(Error::Busy);
        }
        let slot = self
            .inner
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Busy)?;
        let bytes = self
            .inner
            .bytes
            .clone()
            .try_acquire_many_owned(bytes)
            .map_err(|_| Error::Busy)?;
        let expires = context
            .authority
            .as_ref()
            .map_or(now + TTL, |a| a.expires.min(now + TTL));
        let id = uuid::Uuid::new_v4().to_string();
        let ticket = Arc::new(Ticket {
            id: id.clone(),
            selection,
            context,
            expires,
            cancel: CancellationToken::new(),
            _slot: Arc::new(slot),
            _bytes: bytes,
        });
        tickets.insert(id.clone(), ticket.clone());
        controls.insert(id.clone(), Arc::downgrade(&ticket));
        // One bounded task per admitted ticket, with weak ownership. Revocation
        // removes retained metadata immediately, not only on the next request.
        let inner = Arc::downgrade(&self.inner);
        let weak = Arc::downgrade(&ticket);
        let slot = ticket._slot.clone();
        let context = ticket.context.clone();
        let cancel = ticket.cancel.clone();
        tokio::spawn(async move {
            let _slot = slot; // Cancel storms cannot enqueue unbudgeted cleanup tasks.
            let revoked = async {
                tokio::select! {biased;
                    _=cancel.cancelled()=>{},_=context.workspace_cancel.cancelled()=>{},
                    _=async { if let Some(a)=&context.authority { tokio::select!{_=a.cancel.cancelled()=>{},_=tokio::time::sleep_until(a.expires.into())=>{}} }else{std::future::pending::<()>().await;} }=>{},
                }
            };
            tokio::pin!(revoked);
            let expired = tokio::select! {biased; _=&mut revoked=>false,_=tokio::time::sleep_until(expires.into())=>true};
            if let Some(inner) = inner.upgrade() {
                inner.tickets.lock().unwrap().remove(&id);
            }
            // Admission expiry is not a maximum ZIP duration. Weak cancellation
            // lookup and the existing admitted Arc remain valid until completion.
            if expired {
                revoked.await;
            }
            cancel.cancel();
            if let Some(inner) = inner.upgrade() {
                inner.tickets.lock().unwrap().remove(&id);
                inner.controls.lock().unwrap().remove(&id);
            }
            drop(weak);
        });
        Ok(ticket)
    }
    pub(super) fn resolve(&self, id: &str, context: &Context) -> Result<Arc<Ticket>, Error> {
        self.resolve_at(id, context, Instant::now())
    }
    fn resolve_at(&self, id: &str, context: &Context, now: Instant) -> Result<Arc<Ticket>, Error> {
        let mut tickets = self.inner.tickets.lock().unwrap();
        Self::sweep(&mut tickets, now);
        let ticket = tickets.get(id).ok_or(Error::Gone)?;
        if !ticket.context.matches(context) {
            return Err(Error::Forbidden);
        }
        if !context.live(now) {
            return Err(Error::Gone);
        }
        Ok(ticket.clone()) // Never renew expiry on GET/HEAD/retry.
    }
    pub(super) fn cancel(&self, id: &str, context: &Context) -> Result<(), Error> {
        let mut tickets = self.inner.tickets.lock().unwrap();
        let mut controls = self.inner.controls.lock().unwrap();
        let ticket = controls
            .get(id)
            .and_then(Weak::upgrade)
            .ok_or(Error::Gone)?;
        if !ticket.context.matches(context) {
            return Err(Error::Forbidden);
        }
        if !context.live(Instant::now()) {
            return Err(Error::Gone);
        }
        ticket.cancel.cancel();
        tickets.remove(id);
        controls.remove(id);
        Ok(())
    }
    pub(super) fn revoke_owner(&self, owner: &str) {
        let mut tickets = self.inner.tickets.lock().unwrap();
        let mut controls = self.inner.controls.lock().unwrap();
        controls.retain(|_, weak| {
            if let Some(ticket) = weak.upgrade() {
                if ticket.context.owner == owner {
                    ticket.cancel.cancel();
                    false
                } else {
                    true
                }
            } else {
                false
            }
        });
        tickets.retain(|_, ticket| ticket.context.owner != owner);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context() -> Context {
        Context {
            owner: uuid::Uuid::new_v4().to_string(),
            workspace: uuid::Uuid::new_v4().to_string(),
            generation: 1,
            caller: Caller::Browser("127.0.0.1".into()),
            workspace_cancel: CancellationToken::new(),
            authority: None,
        }
    }
    fn selection(n: usize) -> Selection {
        Selection::parse(serde_json::json!({"path":"folder","ids":(0..n).map(|i|format!("child-{i}")).collect::<Vec<_>>()} ).to_string().as_bytes()).unwrap()
    }
    #[tokio::test]
    async fn large_metadata_selection_is_reusable_but_never_renews_expiry() {
        let registry = Registry::new();
        let context = context();
        let now = Instant::now();
        let ticket = registry
            .prepare_at(context.clone(), selection(5001), now)
            .unwrap();
        assert_eq!(ticket.selection.ids.len(), 5001);
        let second = registry
            .resolve_at(&ticket.id, &context, now + Duration::from_secs(90))
            .unwrap();
        assert!(Arc::ptr_eq(&ticket, &second));
        assert_eq!(
            second.remaining(now + Duration::from_secs(90)),
            Duration::from_secs(30)
        );
        assert!(matches!(
            registry.resolve_at(&ticket.id, &context, now + TTL),
            Err(Error::Gone)
        ));
        assert!(!ticket.cancel.is_cancelled()); // Existing admitted stream stays alive.
        registry.cancel(&ticket.id, &context).unwrap(); // Still cancelable after admission expiry.
        assert!(ticket.cancel.is_cancelled());
    }
    #[tokio::test]
    async fn exact_owner_generation_peer_and_grant_are_required_even_with_known_ticket() {
        let registry = Registry::new();
        let mut context = context();
        context.authority = Some(Authority {
            cancel: CancellationToken::new(),
            expires: Instant::now() + TTL,
        });
        let ticket = registry.prepare(context.clone(), selection(1)).unwrap();
        let mut changed = context.clone();
        changed.owner = uuid::Uuid::new_v4().to_string();
        assert!(matches!(
            registry.resolve(&ticket.id, &changed),
            Err(Error::Forbidden)
        ));
        let mut changed = context.clone();
        changed.generation += 1;
        assert!(matches!(
            registry.resolve(&ticket.id, &changed),
            Err(Error::Forbidden)
        ));
        changed = context.clone();
        changed.caller = Caller::Browser("127.0.0.2".into());
        assert!(matches!(
            registry.resolve(&ticket.id, &changed),
            Err(Error::Forbidden)
        ));
        changed = context.clone();
        changed.authority.as_mut().unwrap().cancel = CancellationToken::new();
        assert!(matches!(
            registry.resolve(&ticket.id, &changed),
            Err(Error::Forbidden)
        ));
        changed = context.clone();
        changed.workspace_cancel = CancellationToken::new();
        assert!(matches!(
            registry.resolve(&ticket.id, &changed),
            Err(Error::Forbidden)
        ));
        assert!(!ticket.cancel.is_cancelled());
        context.authority.as_ref().unwrap().cancel.cancel();
        assert!(matches!(
            registry.resolve(&ticket.id, &context),
            Err(Error::Gone)
        ));
        assert!(ticket.cancel.is_cancelled());
    }
    #[tokio::test]
    async fn independent_cancel_owner_revoke_and_retained_metadata_budget() {
        let registry = Registry::new();
        let context = context();
        let a = registry.prepare(context.clone(), selection(1)).unwrap();
        let b = registry.prepare(context.clone(), selection(1)).unwrap();
        registry.cancel(&a.id, &context).unwrap();
        assert!(a.cancel.is_cancelled());
        assert!(!b.cancel.is_cancelled());
        assert!(registry.resolve(&b.id, &context).is_ok());
        assert_eq!(registry.inner.slots.available_permits(), 62); // Still held by real owners.
        drop(a);
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.inner.slots.available_permits(), 63);
        registry.revoke_owner(&context.owner);
        assert!(b.cancel.is_cancelled());
        drop(b);
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.inner.slots.available_permits(), 64);
    }
    #[tokio::test]
    async fn caller_quota_global_slots_and_revocation_task_stay_bounded() {
        let registry = Registry::new();
        let context = context();
        for _ in 0..4 {
            registry.prepare(context.clone(), selection(1)).unwrap();
        }
        assert!(matches!(
            registry.prepare(context.clone(), selection(1)),
            Err(Error::Busy)
        ));
        let mut other = context.clone();
        other.caller = Caller::Browser("127.0.0.2".into());
        assert!(registry.prepare(other, selection(1)).is_ok());
        context.workspace_cancel.cancel();
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert!(registry.inner.tickets.lock().unwrap().is_empty());
        assert_eq!(registry.inner.slots.available_permits(), 64);
        assert_eq!(registry.inner.bytes.available_permits(), MAX_METADATA);
    }
    #[tokio::test]
    async fn cancel_storm_keeps_cleanup_tasks_inside_global_slot_limit() {
        let registry = Registry::new();
        // No await: canceled timer tasks have not had a chance to finish.
        for _ in 0..MAX_TICKETS {
            let context = context();
            let ticket = registry.prepare(context.clone(), selection(1)).unwrap();
            registry.cancel(&ticket.id, &context).unwrap();
        }
        assert_eq!(registry.inner.slots.available_permits(), 0);
        assert!(matches!(
            registry.prepare(context(), selection(1)),
            Err(Error::Busy)
        ));
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.inner.slots.available_permits(), MAX_TICKETS);
        assert!(registry.prepare(context(), selection(1)).is_ok());
    }
    #[tokio::test]
    async fn actual_metadata_bytes_are_global_budget_not_only_entry_count() {
        let registry = Registry::new();
        let mut saved = Vec::new();
        let ids: Vec<_> = (0..1000)
            .map(|i| format!("{i}-{}", "a".repeat(1400)))
            .collect();
        let body = serde_json::json!({"path":"","ids":ids}).to_string();
        let mut refused = false;
        for _ in 0..MAX_TICKETS {
            match registry.prepare(context(), Selection::parse(body.as_bytes()).unwrap()) {
                Ok(ticket) => saved.push(ticket),
                Err(Error::Busy) => {
                    refused = true;
                    break;
                }
                Err(error) => panic!("unexpected {error:?}"),
            }
        }
        assert!(refused);
        assert!(saved.len() < MAX_TICKETS);
        for ticket in &saved {
            registry.revoke_owner(&ticket.context.owner);
        }
        let charged = registry.inner.bytes.available_permits();
        assert!(charged < MAX_METADATA); // Real Arc owners retain their metadata budget.
        saved.clear();
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.inner.bytes.available_permits(), MAX_METADATA);
    }
    #[test]
    fn rejects_oversized_ambiguous_and_invalid_metadata() {
        assert!(matches!(
            Selection::parse(&vec![b' '; MAX_BODY + 1]),
            Err(Error::TooLarge)
        ));
        for body in [
            r#"{"path":"","ids":["a","a"]}"#,
            r#"{"path":"","ids":["a"],"unknown":1}"#,
            r#"{"path":"","ids":[true]}"#,
            r#"{"path":"","ids":[""]}"#,
            r#"{"path":"","ids":["a"],"ids":["b"]}"#,
        ] {
            assert!(matches!(
                Selection::parse(body.as_bytes()),
                Err(Error::Invalid)
            ));
        }
        let body=serde_json::json!({"path":"","ids":(0..MAX_IDS+1).map(|i|i.to_string()).collect::<Vec<_>>()}).to_string();
        assert!(matches!(
            Selection::parse(body.as_bytes()),
            Err(Error::TooLarge)
        ));
    }
}
