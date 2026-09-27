// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'network_state.dart';

class NetworkStateMapper extends ClassMapperBase<NetworkState> {
  NetworkStateMapper._();

  static NetworkStateMapper? _instance;
  static NetworkStateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = NetworkStateMapper._());
      LocalNetworkAddressMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'NetworkState';

  static List<String> _$localIps(NetworkState v) => v.localIps;
  static const Field<NetworkState, List<String>> _f$localIps = Field(
    'localIps',
    _$localIps,
  );
  static bool _$initialized(NetworkState v) => v.initialized;
  static const Field<NetworkState, bool> _f$initialized = Field(
    'initialized',
    _$initialized,
  );
  static List<LocalNetworkAddress> _$addresses(NetworkState v) => v.addresses;
  static const Field<NetworkState, List<LocalNetworkAddress>> _f$addresses =
      Field('addresses', _$addresses, opt: true, def: const []);
  static bool _$vpnDetected(NetworkState v) => v.vpnDetected;
  static const Field<NetworkState, bool> _f$vpnDetected = Field(
    'vpnDetected',
    _$vpnDetected,
    opt: true,
    def: false,
  );
  static bool _$vpnKnown(NetworkState v) => v.vpnKnown;
  static const Field<NetworkState, bool> _f$vpnKnown = Field(
    'vpnKnown',
    _$vpnKnown,
    opt: true,
    def: false,
  );
  static bool _$proxyEnabled(NetworkState v) => v.proxyEnabled;
  static const Field<NetworkState, bool> _f$proxyEnabled = Field(
    'proxyEnabled',
    _$proxyEnabled,
    opt: true,
    def: false,
  );
  static bool _$proxyKnown(NetworkState v) => v.proxyKnown;
  static const Field<NetworkState, bool> _f$proxyKnown = Field(
    'proxyKnown',
    _$proxyKnown,
    opt: true,
    def: false,
  );
  static List<String> _$tunnelInterfaces(NetworkState v) => v.tunnelInterfaces;
  static const Field<NetworkState, List<String>> _f$tunnelInterfaces = Field(
    'tunnelInterfaces',
    _$tunnelInterfaces,
    opt: true,
    def: const [],
  );

  @override
  final MappableFields<NetworkState> fields = const {
    #localIps: _f$localIps,
    #initialized: _f$initialized,
    #addresses: _f$addresses,
    #vpnDetected: _f$vpnDetected,
    #vpnKnown: _f$vpnKnown,
    #proxyEnabled: _f$proxyEnabled,
    #proxyKnown: _f$proxyKnown,
    #tunnelInterfaces: _f$tunnelInterfaces,
  };

  static NetworkState _instantiate(DecodingData data) {
    return NetworkState(
      localIps: data.dec(_f$localIps),
      initialized: data.dec(_f$initialized),
      addresses: data.dec(_f$addresses),
      vpnDetected: data.dec(_f$vpnDetected),
      vpnKnown: data.dec(_f$vpnKnown),
      proxyEnabled: data.dec(_f$proxyEnabled),
      proxyKnown: data.dec(_f$proxyKnown),
      tunnelInterfaces: data.dec(_f$tunnelInterfaces),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static NetworkState fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<NetworkState>(map);
  }

  static NetworkState deserialize(String json) {
    return ensureInitialized().decodeJson<NetworkState>(json);
  }
}

mixin NetworkStateMappable {
  String serialize() {
    return NetworkStateMapper.ensureInitialized().encodeJson<NetworkState>(
      this as NetworkState,
    );
  }

  Map<String, dynamic> toJson() {
    return NetworkStateMapper.ensureInitialized().encodeMap<NetworkState>(
      this as NetworkState,
    );
  }

  NetworkStateCopyWith<NetworkState, NetworkState, NetworkState> get copyWith =>
      _NetworkStateCopyWithImpl<NetworkState, NetworkState>(
        this as NetworkState,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return NetworkStateMapper.ensureInitialized().stringifyValue(
      this as NetworkState,
    );
  }

  @override
  bool operator ==(Object other) {
    return NetworkStateMapper.ensureInitialized().equalsValue(
      this as NetworkState,
      other,
    );
  }

  @override
  int get hashCode {
    return NetworkStateMapper.ensureInitialized().hashValue(
      this as NetworkState,
    );
  }
}

extension NetworkStateValueCopy<$R, $Out>
    on ObjectCopyWith<$R, NetworkState, $Out> {
  NetworkStateCopyWith<$R, NetworkState, $Out> get $asNetworkState =>
      $base.as((v, t, t2) => _NetworkStateCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class NetworkStateCopyWith<$R, $In extends NetworkState, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get localIps;
  ListCopyWith<
    $R,
    LocalNetworkAddress,
    LocalNetworkAddressCopyWith<$R, LocalNetworkAddress, LocalNetworkAddress>
  >
  get addresses;
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>
  get tunnelInterfaces;
  $R call({
    List<String>? localIps,
    bool? initialized,
    List<LocalNetworkAddress>? addresses,
    bool? vpnDetected,
    bool? vpnKnown,
    bool? proxyEnabled,
    bool? proxyKnown,
    List<String>? tunnelInterfaces,
  });
  NetworkStateCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _NetworkStateCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, NetworkState, $Out>
    implements NetworkStateCopyWith<$R, NetworkState, $Out> {
  _NetworkStateCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<NetworkState> $mapper =
      NetworkStateMapper.ensureInitialized();
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get localIps =>
      ListCopyWith(
        $value.localIps,
        (v, t) => ObjectCopyWith(v, $identity, t),
        (v) => call(localIps: v),
      );
  @override
  ListCopyWith<
    $R,
    LocalNetworkAddress,
    LocalNetworkAddressCopyWith<$R, LocalNetworkAddress, LocalNetworkAddress>
  >
  get addresses => ListCopyWith(
    $value.addresses,
    (v, t) => v.copyWith.$chain(t),
    (v) => call(addresses: v),
  );
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>>
  get tunnelInterfaces => ListCopyWith(
    $value.tunnelInterfaces,
    (v, t) => ObjectCopyWith(v, $identity, t),
    (v) => call(tunnelInterfaces: v),
  );
  @override
  $R call({
    List<String>? localIps,
    bool? initialized,
    List<LocalNetworkAddress>? addresses,
    bool? vpnDetected,
    bool? vpnKnown,
    bool? proxyEnabled,
    bool? proxyKnown,
    List<String>? tunnelInterfaces,
  }) => $apply(
    FieldCopyWithData({
      if (localIps != null) #localIps: localIps,
      if (initialized != null) #initialized: initialized,
      if (addresses != null) #addresses: addresses,
      if (vpnDetected != null) #vpnDetected: vpnDetected,
      if (vpnKnown != null) #vpnKnown: vpnKnown,
      if (proxyEnabled != null) #proxyEnabled: proxyEnabled,
      if (proxyKnown != null) #proxyKnown: proxyKnown,
      if (tunnelInterfaces != null) #tunnelInterfaces: tunnelInterfaces,
    }),
  );
  @override
  NetworkState $make(CopyWithData data) => NetworkState(
    localIps: data.get(#localIps, or: $value.localIps),
    initialized: data.get(#initialized, or: $value.initialized),
    addresses: data.get(#addresses, or: $value.addresses),
    vpnDetected: data.get(#vpnDetected, or: $value.vpnDetected),
    vpnKnown: data.get(#vpnKnown, or: $value.vpnKnown),
    proxyEnabled: data.get(#proxyEnabled, or: $value.proxyEnabled),
    proxyKnown: data.get(#proxyKnown, or: $value.proxyKnown),
    tunnelInterfaces: data.get(#tunnelInterfaces, or: $value.tunnelInterfaces),
  );

  @override
  NetworkStateCopyWith<$R2, NetworkState, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _NetworkStateCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

