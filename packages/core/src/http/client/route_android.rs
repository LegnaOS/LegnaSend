//! Read-only identities supplied by Android's ConnectivityManager. This registry
//! never changes process routing. Socket selection remains per-client/per-FD.
// Host builds compile this module only for its platform-independent registry tests.
#![cfg_attr(not(target_os = "android"), allow(dead_code))]
use super::ClientError;
use serde::Deserialize;
use std::{
    collections::HashMap,
    io,
    net::IpAddr,
    sync::{OnceLock, RwLock},
};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Network {
    handle: String,
    lease: String,
    interface_name: String,
    addresses: Vec<String>,
    vpn: bool,
    wifi: bool,
    cellular: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    epoch: String,
    revision: u64,
    networks: Vec<Network>,
}
#[derive(Default)]
struct Registry {
    epoch: Option<String>,
    revision: u64,
    networks: HashMap<u64, Network>,
}
static REGISTRY: OnceLock<RwLock<Registry>> = OnceLock::new();
fn registry() -> &'static RwLock<Registry> {
    REGISTRY.get_or_init(Default::default)
}
fn invalid() -> ClientError {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "local-route-invalid: Invalid Android network snapshot",
    )
    .into()
}
fn unavailable() -> io::Error {
    io::Error::new(
        io::ErrorKind::AddrNotAvailable,
        "local-route-unavailable: Android network identity changed",
    )
}
fn handle(value: &str) -> Option<u64> {
    value
        .parse::<u64>()
        .ok()
        .filter(|v| *v != 0 && v.to_string() == value)
}
fn valid_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|v| v.to_string() == value)
}
impl Registry {
    fn apply(&mut self, snapshot: Snapshot) -> Result<(), ClientError> {
        if !valid_uuid(&snapshot.epoch) || snapshot.revision == 0 || snapshot.networks.len() > 64 {
            return Err(invalid());
        }
        let mut networks = HashMap::new();
        for network in snapshot.networks {
            let id = handle(&network.handle).ok_or_else(invalid)?;
            if !valid_uuid(&network.lease)
                || network.interface_name.is_empty()
                || network.interface_name.len() > 1024
                || network.interface_name.chars().any(char::is_control)
                || network.addresses.is_empty()
                || network.addresses.len() > 64
                || network
                    .addresses
                    .iter()
                    .any(|a| a.parse::<IpAddr>().is_err())
                || networks.contains_key(&id)
            {
                return Err(invalid());
            }
            // Deserialized platform transport flags are intentionally not a routing guarantee.
            let _ = (network.vpn, network.wifi, network.cellular);
            networks.insert(id, network);
        }
        if self.epoch.as_ref().is_some_and(|e| e != &snapshot.epoch) {
            return Err(invalid());
        }
        if self.epoch.is_some() && snapshot.revision <= self.revision {
            return Ok(());
        }
        self.epoch = Some(snapshot.epoch);
        self.revision = snapshot.revision;
        self.networks = networks;
        Ok(())
    }
    fn matches(&self, route: &AndroidNetworkRoute) -> bool {
        self.networks.get(&route.handle).is_some_and(|network| {
            network.lease == route.lease
                && self.epoch.as_deref() == Some(&route.epoch)
                && network.interface_name == route.interface
                && network
                    .addresses
                    .iter()
                    .any(|address| address.parse::<IpAddr>().ok() == Some(route.address))
        })
    }
}
pub(super) fn configure(raw: Option<&str>) -> Result<(), ClientError> {
    let mut state = registry().write().map_err(|_| invalid())?;
    let Some(raw) = raw else {
        state.networks.clear();
        return Ok(());
    };
    if raw.len() > 128 * 1024 {
        state.networks.clear();
        return Err(invalid());
    }
    let snapshot = match serde_json::from_str::<Snapshot>(raw) {
        Ok(s) => s,
        Err(_) => {
            state.networks.clear();
            return Err(invalid());
        }
    };
    match state.apply(snapshot) {
        Ok(()) => Ok(()),
        Err(e) => {
            state.networks.clear();
            Err(e)
        }
    }
}
#[derive(Clone, Debug)]
pub(super) struct AndroidNetworkRoute {
    handle: u64,
    epoch: String,
    lease: String,
    interface: String,
    address: IpAddr,
}
impl AndroidNetworkRoute {
    pub(super) fn new(
        handle_value: &str,
        epoch_value: &str,
        interface: &str,
        address: IpAddr,
    ) -> Result<Self, ClientError> {
        let (epoch, lease) = epoch_value.split_once(':').ok_or_else(invalid)?;
        if !valid_uuid(epoch) || !valid_uuid(lease) {
            return Err(invalid());
        }
        let route = Self {
            handle: handle(handle_value).ok_or_else(invalid)?,
            epoch: epoch.into(),
            lease: lease.into(),
            interface: interface.into(),
            address,
        };
        route.validate()?;
        Ok(route)
    }
    pub(super) fn validate(&self) -> Result<(), ClientError> {
        if registry().read().map_err(|_| unavailable())?.matches(self) {
            Ok(())
        } else {
            Err(unavailable().into())
        }
    }
    pub(super) fn bind(&self, socket: &socket2::Socket) -> io::Result<()> {
        self.validate().map_err(|_| unavailable())?;
        #[cfg(target_os = "android")]
        {
            use std::os::fd::AsRawFd;
            if socket.domain()?
                != socket2::Domain::for_address(std::net::SocketAddr::new(self.address, 0))
            {
                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    "local-route-unavailable: Socket address family differs from selected source",
                ));
            }
            #[link(name = "android")]
            unsafe extern "C" {
                fn android_setsocknetwork(network: u64, fd: std::ffi::c_int) -> std::ffi::c_int;
            }
            // Borrow only: the connector owns/closes the socket on every failure.
            if unsafe { android_setsocknetwork(self.handle, socket.as_raw_fd()) } != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    format!(
                        "local-route-unavailable: Android socket binding failed: {}",
                        io::Error::last_os_error()
                    ),
                ));
            }
            Ok(())
        }
        #[cfg(not(target_os = "android"))]
        {
            let _ = socket;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Android Network binding requires Android",
            ))
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(revision: u64, present: bool) -> Snapshot {
        serde_json::from_value(serde_json::json!({"epoch":"11111111-1111-4111-8111-111111111111","revision":revision,"networks":if present {vec![serde_json::json!({"handle":"123","lease":"22222222-2222-4222-8222-222222222222","interfaceName":"wlan0","addresses":["192.0.2.7"],"vpn":false,"wifi":true,"cellular":false})]}else{vec![]}})).unwrap()
    }
    #[test]
    fn shrinking_snapshot_retires_network_and_old_snapshot_cannot_revive_it() {
        let mut state = Registry::default();
        state.apply(snapshot(1, true)).unwrap();
        let route = AndroidNetworkRoute {
            handle: 123,
            epoch: "11111111-1111-4111-8111-111111111111".into(),
            lease: "22222222-2222-4222-8222-222222222222".into(),
            interface: "wlan0".into(),
            address: "192.0.2.7".parse().unwrap(),
        };
        assert!(state.matches(&route));
        state.apply(snapshot(2, false)).unwrap();
        assert!(!state.matches(&route));
        state.apply(snapshot(1, true)).unwrap();
        assert!(!state.matches(&route));
        state.apply(snapshot(3, true)).unwrap();
        let mut wrong = route.clone();
        wrong.interface = "other".into();
        assert!(!state.matches(&wrong));
        wrong = route;
        wrong.lease = uuid::Uuid::new_v4().to_string();
        assert!(!state.matches(&wrong));
        assert_eq!(handle("0"), None);
        assert_eq!(handle("0123"), None);
    }
}
