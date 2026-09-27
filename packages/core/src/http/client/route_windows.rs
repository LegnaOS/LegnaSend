//! Windows TCP egress interface binding. This never alters global routes or VPN policy.
use socket2::Socket;
use std::{io, mem, net::IpAddr, os::windows::io::AsRawSocket};
use windows_sys::Win32::Networking::WinSock::{
    AF_INET, AF_INET6, IP_UNICAST_IF, IPPROTO_IP, IPPROTO_IPV6, IPV6_UNICAST_IF, SO_PROTOCOL_INFOW,
    SOCKET_ERROR, SOL_SOCKET, WSAGetLastError, WSAPROTOCOL_INFOW, getsockopt, setsockopt,
};

fn error(detail: impl std::fmt::Display) -> io::Error {
    io::Error::new(
        io::ErrorKind::AddrNotAvailable,
        format!("local-route-unavailable: {detail}"),
    )
}

pub(super) fn bind(socket: &Socket, address: IpAddr, index: u32) -> io::Result<()> {
    if index == 0 || (address.is_ipv4() && index > 0x00ff_ffff) {
        return Err(error("Invalid Windows outgoing interface index"));
    }
    // getsockname is not valid on every unbound Windows socket. The provider's
    // protocol record identifies its actual address family before any bind.
    let mut protocol = WSAPROTOCOL_INFOW::default();
    let mut len = mem::size_of_val(&protocol) as i32;
    // SAFETY: the socket is borrowed/live and the output buffer has exactly len bytes.
    let result = unsafe {
        getsockopt(
            socket.as_raw_socket() as _,
            SOL_SOCKET,
            SO_PROTOCOL_INFOW,
            (&mut protocol as *mut WSAPROTOCOL_INFOW).cast(),
            &mut len,
        )
    };
    if result == SOCKET_ERROR {
        return Err(error(io::Error::from_raw_os_error(unsafe {
            WSAGetLastError()
        })));
    }
    let family = if address.is_ipv4() { AF_INET } else { AF_INET6 };
    if len as usize != mem::size_of_val(&protocol) || protocol.iAddressFamily != i32::from(family) {
        return Err(error(
            "Socket family does not match the selected source address",
        ));
    }
    // Microsoft specifies NETWORK byte order for IPv4, HOST byte order for IPv6.
    let (level, option, value) = if address.is_ipv4() {
        (IPPROTO_IP, IP_UNICAST_IF, index.to_be())
    } else {
        (IPPROTO_IPV6, IPV6_UNICAST_IF, index)
    };
    // SAFETY: value is a DWORD; no ownership of the borrowed socket is transferred.
    let result = unsafe {
        setsockopt(
            socket.as_raw_socket() as _,
            level,
            option,
            (&value as *const u32).cast(),
            mem::size_of_val(&value) as i32,
        )
    };
    if result == SOCKET_ERROR {
        return Err(error(io::Error::from_raw_os_error(unsafe {
            WSAGetLastError()
        })));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use socket2::{Domain, Protocol, Type};

    #[test]
    fn selected_windows_interface_is_installed_before_connect() {
        for ipv4 in [true, false] {
            let entry = if_addrs::get_if_addrs()
                .unwrap()
                .into_iter()
                .find(|entry| entry.ip().is_loopback() && entry.ip().is_ipv4() == ipv4)
                .expect("Windows test host needs IPv4 and IPv6 loopback adapters");
            let index = entry.index.unwrap();
            let socket = Socket::new(
                if ipv4 { Domain::IPV4 } else { Domain::IPV6 },
                Type::STREAM,
                Some(Protocol::TCP),
            )
            .unwrap();
            bind(&socket, entry.ip(), index).unwrap();
            let mut actual = 0_u32;
            let mut len = mem::size_of_val(&actual) as i32;
            // Both getters return the interface index in host byte order.
            let result = unsafe {
                getsockopt(
                    socket.as_raw_socket() as _,
                    if ipv4 { IPPROTO_IP } else { IPPROTO_IPV6 },
                    if ipv4 { IP_UNICAST_IF } else { IPV6_UNICAST_IF },
                    (&mut actual as *mut u32).cast(),
                    &mut len,
                )
            };
            assert_eq!(result, 0);
            assert_eq!(actual, index);
            assert!(bind(&socket, entry.ip(), 0).is_err());
            let wrong = if ipv4 { "::1" } else { "127.0.0.1" }.parse().unwrap();
            assert!(bind(&socket, wrong, index).is_err());
        }
    }
}
