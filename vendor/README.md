# Task-local socket binding patches

These directories retain the published upstream sources and licenses for **reqwest 0.13.4** and **hyper-util 0.1.20**. The root Cargo manifest selects them through `[patch.crates-io]`; versions and all unrelated behavior stay unchanged. Registry installation markers and checksums are omitted because the sources now contain maintained local modifications.

## Maintained changes

- `reqwest/src/async_impl/client.rs`: optional per-client `Arc<Fn(&socket2::Socket) -> io::Result<()> + Send + Sync>` configuration, `ClientBuilder::socket_callback`, a presence-only Debug field, and forwarding to the existing `HttpConnector` before TLS wrapping. The two manifests declare socket2 0.6.5 for non-browser targets.
- `hyper-util/src/client/legacy/connect/http.rs`: optional callback in the cloneable connector configuration, `set_socket_callback`, and invocation immediately after each TCP socket is created, before binding or connecting. Existing test configuration literals initialize the new field to `None`.
- The hyper-util manifests narrow its existing `>=0.5.9, <0.7` socket2 range to the already used `0.6.5`, ensuring callbacks borrow the same Socket type across both crates.
- Defaults are `None`. No process-global callback, raw-socket ownership transfer, dependency upgrade, TLS handshake change, certificate validation change, or private transfer protocol is introduced.

Callback errors close the newly created socket and fail that connection attempt. Any subsequent address attempt still invokes the same callback; it never retries with an unbound socket. Existing pooled connections retain their original binding. The application must additionally validate the selected route before each request, as LegnaSend's v2 client does.

The hook covers the regular TCP connector, including its TLS wrapper. QUIC, Unix sockets, named pipes, and SOCKS have separate connection paths and are **not** covered. LegnaSend's route-constrained client disables proxies and uses the original LocalSend v2 HTTP/TLS TCP path; do not broaden this feature to other transports without implementing their equivalent constraints.

## Upstream refresh checklist

1. Reapply only the changes above; keep upstream licensing intact.
2. Review connector creation and alternate transport paths for any new bypass.
3. Run `cargo test -p localsend --features full --test client_socket_callback --test client_local_route`.
4. Check Windows and Android target compilation. Run the platform-specific interface/Network tests on those operating systems before claiming runtime validation.
5. Preserve fail-closed behavior and the absence of process-wide network binding.

Microsoft specifies IPv4 `IP_UNICAST_IF` indices in network byte order and IPv6 `IPV6_UNICAST_IF` indices in host byte order: [IPv4 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options), [IPv6 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options).
