//! Task-local connection constraints. They never change process routing or VPN policy.
use super::ClientError;
use std::{io, net::IpAddr};

#[cfg(any(target_os = "android", test))]
#[path = "route_android.rs"]
mod android;
#[cfg(target_os = "windows")]
#[path = "route_windows.rs"]
mod windows;

/// Android requires an explicit Network handle in addition to a source address.
/// Interface constraints do not override system VPN/firewall policy.
pub fn interface_binding_supported() -> bool {
    cfg!(any(
        target_os = "linux",
        target_os = "macos",
        target_os = "ios",
        target_os = "windows"
    ))
}

#[derive(Clone, Debug)]
pub(super) struct LocalRoute {
    address: IpAddr,
    interface: String,
    index: Option<u32>,
    #[cfg(target_os = "android")]
    network: Option<android::AndroidNetworkRoute>,
}
fn invalid(message: &str) -> ClientError {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("local-route-invalid: {message}"),
    )
    .into()
}
fn unavailable(message: &str) -> ClientError {
    io::Error::new(
        io::ErrorKind::AddrNotAvailable,
        format!("local-route-unavailable: {message}"),
    )
    .into()
}
impl LocalRoute {
    pub(super) fn parse(
        address: Option<String>,
        interface: Option<String>,
    ) -> Result<Option<Self>, ClientError> {
        let (address, interface) = match (address, interface) {
            (None, None) => return Ok(None),
            (Some(a), Some(i)) if !a.is_empty() && !i.is_empty() && i.len() <= 256 => (a, i),
            _ => {
                return Err(invalid(
                    "Local source address and interface must be supplied together",
                ));
            }
        };
        let address: IpAddr = address
            .parse()
            .map_err(|_| invalid("Invalid local source IP address"))?;
        if address.is_unspecified() || address.is_multicast() {
            return Err(invalid("Invalid local source IP address"));
        }
        let interfaces = if_addrs::get_if_addrs()
            .map_err(|_| unavailable("Network interfaces could not be enumerated"))?;
        let entry = interfaces
            .iter()
            .find(|entry| {
                entry.name == interface
                    && entry.ip() == address
                    && matches!(
                        entry.oper_status,
                        if_addrs::IfOperStatus::Up | if_addrs::IfOperStatus::Unknown
                    )
            })
            .ok_or_else(|| {
                unavailable("Selected source address is not active on the selected interface")
            })?;
        #[cfg(target_os = "windows")]
        if entry
            .index
            .is_none_or(|index| index == 0 || (address.is_ipv4() && index > 0x00ff_ffff))
        {
            return Err(unavailable(
                "Selected Windows interface has no usable index",
            ));
        }
        Ok(Some(Self {
            address,
            interface,
            index: entry.index,
            #[cfg(target_os = "android")]
            network: None,
        }))
    }
    pub(super) fn with_android_network(
        self,
        handle: Option<String>,
        epoch: Option<String>,
    ) -> Result<Self, ClientError> {
        match (handle, epoch) {
            (None, None) => Ok(self),
            #[cfg(target_os = "android")]
            (Some(handle), Some(epoch)) => {
                let network = android::AndroidNetworkRoute::new(
                    &handle,
                    &epoch,
                    &self.interface,
                    self.address,
                )?;
                Ok(Self {
                    network: Some(network),
                    ..self
                })
            }
            _ => Err(invalid(
                "An Android Network handle and epoch are required on Android",
            )),
        }
    }

    pub(super) fn validate(&self) -> Result<(), ClientError> {
        #[cfg(target_os = "android")]
        if let Some(network) = &self.network {
            network.validate()?;
        }
        if if_addrs::get_if_addrs()
            .map_err(|_| unavailable("Network interfaces could not be enumerated"))?
            .iter()
            .any(|entry| {
                entry.name == self.interface
                    && entry.index == self.index
                    && entry.ip() == self.address
                    && matches!(
                        entry.oper_status,
                        if_addrs::IfOperStatus::Up | if_addrs::IfOperStatus::Unknown
                    )
            })
        {
            Ok(())
        } else {
            Err(unavailable("Selected local route is no longer available"))
        }
    }
    pub(super) fn apply(&self, builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
        let builder = builder.local_address(self.address);
        // Android without an explicit Network handle intentionally binds only source IP.
        #[cfg(any(target_os = "linux", target_os = "macos", target_os = "ios"))]
        let builder = builder.interface(&self.interface);
        #[cfg(target_os = "windows")]
        let builder = {
            let route = self.clone();
            builder.socket_callback(move |socket| {
                route.validate().map_err(|error| {
                    io::Error::new(io::ErrorKind::AddrNotAvailable, error.to_string())
                })?;
                windows::bind(
                    socket,
                    route.address,
                    route.index.ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::AddrNotAvailable,
                            "local-route-unavailable: Missing interface index",
                        )
                    })?,
                )
            })
        };
        #[cfg(target_os = "android")]
        let builder = if let Some(network) = &self.network {
            let network = network.clone();
            builder.socket_callback(move |socket| network.bind(socket))
        } else {
            builder
        };
        builder
    }
}

/// Replaces Android Network identities; this does not bind the process to a network.
pub fn configure_android_network_routes(snapshot: Option<&str>) -> Result<(), ClientError> {
    #[cfg(target_os = "android")]
    {
        android::configure(snapshot)
    }
    #[cfg(not(target_os = "android"))]
    {
        if snapshot.is_none() {
            Ok(())
        } else {
            Err(invalid(
                "Android Network identities are only supported on Android",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interface_identity_change_invalidates_existing_route() {
        let entry = if_addrs::get_if_addrs()
            .unwrap()
            .into_iter()
            .find(|i| i.ip().is_loopback())
            .unwrap();
        let mut route = LocalRoute::parse(Some(entry.ip().to_string()), Some(entry.name))
            .unwrap()
            .unwrap();
        route.validate().unwrap();
        route.index = Some(u32::MAX);
        assert!(route.validate().is_err());
    }
}
