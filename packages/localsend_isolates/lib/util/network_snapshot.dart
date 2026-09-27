// Interface enumeration is performed by Rust's worker pool, not the UI isolate.
// Keep this public facade so the app does not depend on the bridge implementation.
export 'package:localsend_isolates/rust/api/network.dart' show RsNetworkAddress, getNetworkAddresses;
