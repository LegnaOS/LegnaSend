// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'local_network_address.dart';

class LocalNetworkAddressMapper extends ClassMapperBase<LocalNetworkAddress> {
  LocalNetworkAddressMapper._();

  static LocalNetworkAddressMapper? _instance;
  static LocalNetworkAddressMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = LocalNetworkAddressMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'LocalNetworkAddress';

  static String _$interfaceName(LocalNetworkAddress v) => v.interfaceName;
  static const Field<LocalNetworkAddress, String> _f$interfaceName = Field(
    'interfaceName',
    _$interfaceName,
  );
  static int? _$interfaceIndex(LocalNetworkAddress v) => v.interfaceIndex;
  static const Field<LocalNetworkAddress, int> _f$interfaceIndex = Field(
    'interfaceIndex',
    _$interfaceIndex,
    opt: true,
  );
  static String _$address(LocalNetworkAddress v) => v.address;
  static const Field<LocalNetworkAddress, String> _f$address = Field(
    'address',
    _$address,
  );
  static int? _$prefixLength(LocalNetworkAddress v) => v.prefixLength;
  static const Field<LocalNetworkAddress, int> _f$prefixLength = Field(
    'prefixLength',
    _$prefixLength,
    opt: true,
  );
  static bool _$wifi(LocalNetworkAddress v) => v.wifi;
  static const Field<LocalNetworkAddress, bool> _f$wifi = Field(
    'wifi',
    _$wifi,
    opt: true,
    def: false,
  );
  static String? _$androidNetworkHandle(LocalNetworkAddress v) =>
      v.androidNetworkHandle;
  static const Field<LocalNetworkAddress, String> _f$androidNetworkHandle =
      Field('androidNetworkHandle', _$androidNetworkHandle, opt: true);
  static String? _$androidNetworkEpoch(LocalNetworkAddress v) =>
      v.androidNetworkEpoch;
  static const Field<LocalNetworkAddress, String> _f$androidNetworkEpoch =
      Field('androidNetworkEpoch', _$androidNetworkEpoch, opt: true);
  static bool? _$androidVpn(LocalNetworkAddress v) => v.androidVpn;
  static const Field<LocalNetworkAddress, bool> _f$androidVpn = Field(
    'androidVpn',
    _$androidVpn,
    opt: true,
  );
  static bool _$cellular(LocalNetworkAddress v) => v.cellular;
  static const Field<LocalNetworkAddress, bool> _f$cellular = Field(
    'cellular',
    _$cellular,
    opt: true,
    def: false,
  );

  @override
  final MappableFields<LocalNetworkAddress> fields = const {
    #interfaceName: _f$interfaceName,
    #interfaceIndex: _f$interfaceIndex,
    #address: _f$address,
    #prefixLength: _f$prefixLength,
    #wifi: _f$wifi,
    #androidNetworkHandle: _f$androidNetworkHandle,
    #androidNetworkEpoch: _f$androidNetworkEpoch,
    #androidVpn: _f$androidVpn,
    #cellular: _f$cellular,
  };

  static LocalNetworkAddress _instantiate(DecodingData data) {
    return LocalNetworkAddress(
      interfaceName: data.dec(_f$interfaceName),
      interfaceIndex: data.dec(_f$interfaceIndex),
      address: data.dec(_f$address),
      prefixLength: data.dec(_f$prefixLength),
      wifi: data.dec(_f$wifi),
      androidNetworkHandle: data.dec(_f$androidNetworkHandle),
      androidNetworkEpoch: data.dec(_f$androidNetworkEpoch),
      androidVpn: data.dec(_f$androidVpn),
      cellular: data.dec(_f$cellular),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static LocalNetworkAddress fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LocalNetworkAddress>(map);
  }

  static LocalNetworkAddress deserialize(String json) {
    return ensureInitialized().decodeJson<LocalNetworkAddress>(json);
  }
}

mixin LocalNetworkAddressMappable {
  String serialize() {
    return LocalNetworkAddressMapper.ensureInitialized()
        .encodeJson<LocalNetworkAddress>(this as LocalNetworkAddress);
  }

  Map<String, dynamic> toJson() {
    return LocalNetworkAddressMapper.ensureInitialized()
        .encodeMap<LocalNetworkAddress>(this as LocalNetworkAddress);
  }

  LocalNetworkAddressCopyWith<
    LocalNetworkAddress,
    LocalNetworkAddress,
    LocalNetworkAddress
  >
  get copyWith =>
      _LocalNetworkAddressCopyWithImpl<
        LocalNetworkAddress,
        LocalNetworkAddress
      >(this as LocalNetworkAddress, $identity, $identity);
  @override
  String toString() {
    return LocalNetworkAddressMapper.ensureInitialized().stringifyValue(
      this as LocalNetworkAddress,
    );
  }

  @override
  bool operator ==(Object other) {
    return LocalNetworkAddressMapper.ensureInitialized().equalsValue(
      this as LocalNetworkAddress,
      other,
    );
  }

  @override
  int get hashCode {
    return LocalNetworkAddressMapper.ensureInitialized().hashValue(
      this as LocalNetworkAddress,
    );
  }
}

extension LocalNetworkAddressValueCopy<$R, $Out>
    on ObjectCopyWith<$R, LocalNetworkAddress, $Out> {
  LocalNetworkAddressCopyWith<$R, LocalNetworkAddress, $Out>
  get $asLocalNetworkAddress => $base.as(
    (v, t, t2) => _LocalNetworkAddressCopyWithImpl<$R, $Out>(v, t, t2),
  );
}

abstract class LocalNetworkAddressCopyWith<
  $R,
  $In extends LocalNetworkAddress,
  $Out
>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? interfaceName,
    int? interfaceIndex,
    String? address,
    int? prefixLength,
    bool? wifi,
    String? androidNetworkHandle,
    String? androidNetworkEpoch,
    bool? androidVpn,
    bool? cellular,
  });
  LocalNetworkAddressCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _LocalNetworkAddressCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, LocalNetworkAddress, $Out>
    implements LocalNetworkAddressCopyWith<$R, LocalNetworkAddress, $Out> {
  _LocalNetworkAddressCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<LocalNetworkAddress> $mapper =
      LocalNetworkAddressMapper.ensureInitialized();
  @override
  $R call({
    String? interfaceName,
    Object? interfaceIndex = $none,
    String? address,
    Object? prefixLength = $none,
    bool? wifi,
    Object? androidNetworkHandle = $none,
    Object? androidNetworkEpoch = $none,
    Object? androidVpn = $none,
    bool? cellular,
  }) => $apply(
    FieldCopyWithData({
      if (interfaceName != null) #interfaceName: interfaceName,
      if (interfaceIndex != $none) #interfaceIndex: interfaceIndex,
      if (address != null) #address: address,
      if (prefixLength != $none) #prefixLength: prefixLength,
      if (wifi != null) #wifi: wifi,
      if (androidNetworkHandle != $none)
        #androidNetworkHandle: androidNetworkHandle,
      if (androidNetworkEpoch != $none)
        #androidNetworkEpoch: androidNetworkEpoch,
      if (androidVpn != $none) #androidVpn: androidVpn,
      if (cellular != null) #cellular: cellular,
    }),
  );
  @override
  LocalNetworkAddress $make(CopyWithData data) => LocalNetworkAddress(
    interfaceName: data.get(#interfaceName, or: $value.interfaceName),
    interfaceIndex: data.get(#interfaceIndex, or: $value.interfaceIndex),
    address: data.get(#address, or: $value.address),
    prefixLength: data.get(#prefixLength, or: $value.prefixLength),
    wifi: data.get(#wifi, or: $value.wifi),
    androidNetworkHandle: data.get(
      #androidNetworkHandle,
      or: $value.androidNetworkHandle,
    ),
    androidNetworkEpoch: data.get(
      #androidNetworkEpoch,
      or: $value.androidNetworkEpoch,
    ),
    androidVpn: data.get(#androidVpn, or: $value.androidVpn),
    cellular: data.get(#cellular, or: $value.cellular),
  );

  @override
  LocalNetworkAddressCopyWith<$R2, LocalNetworkAddress, $Out2>
  $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _LocalNetworkAddressCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

