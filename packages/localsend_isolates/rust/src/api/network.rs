use localsend::util::interface::{network_addresses, InterfaceFilter};

/// One usable local address with its original OS interface and real prefix.
pub struct RsNetworkAddress {
    pub name: String,
    pub index: Option<u32>,
    pub address: String,
    pub prefix_length: Option<u8>,
    pub is_ipv6: bool,
}

pub fn get_network_addresses(
    whitelist: Option<Vec<String>>,
    blacklist: Option<Vec<String>>,
) -> anyhow::Result<Vec<RsNetworkAddress>> {
    Ok(network_addresses(&InterfaceFilter {
        whitelist,
        blacklist,
    })?
    .into_iter()
    .map(|a| RsNetworkAddress {
        name: a.name,
        index: a.index,
        address: a.address,
        prefix_length: a.prefix_length,
        is_ipv6: a.is_ipv6,
    })
    .collect())
}
