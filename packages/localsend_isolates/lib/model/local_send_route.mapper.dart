// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'local_send_route.dart';

class LocalSendRouteMapper extends ClassMapperBase<LocalSendRoute> {
  LocalSendRouteMapper._();

  static LocalSendRouteMapper? _instance;
  static LocalSendRouteMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = LocalSendRouteMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'LocalSendRoute';

  static String _$interfaceName(LocalSendRoute v) => v.interfaceName;
  static const Field<LocalSendRoute, String> _f$interfaceName = Field(
    'interfaceName',
    _$interfaceName,
  );
  static String _$localAddress(LocalSendRoute v) => v.localAddress;
  static const Field<LocalSendRoute, String> _f$localAddress = Field(
    'localAddress',
    _$localAddress,
  );
  static String? _$androidNetworkHandle(LocalSendRoute v) =>
      v.androidNetworkHandle;
  static const Field<LocalSendRoute, String> _f$androidNetworkHandle = Field(
    'androidNetworkHandle',
    _$androidNetworkHandle,
    opt: true,
  );
  static String? _$androidNetworkEpoch(LocalSendRoute v) =>
      v.androidNetworkEpoch;
  static const Field<LocalSendRoute, String> _f$androidNetworkEpoch = Field(
    'androidNetworkEpoch',
    _$androidNetworkEpoch,
    opt: true,
  );

  @override
  final MappableFields<LocalSendRoute> fields = const {
    #interfaceName: _f$interfaceName,
    #localAddress: _f$localAddress,
    #androidNetworkHandle: _f$androidNetworkHandle,
    #androidNetworkEpoch: _f$androidNetworkEpoch,
  };

  static LocalSendRoute _instantiate(DecodingData data) {
    return LocalSendRoute(
      interfaceName: data.dec(_f$interfaceName),
      localAddress: data.dec(_f$localAddress),
      androidNetworkHandle: data.dec(_f$androidNetworkHandle),
      androidNetworkEpoch: data.dec(_f$androidNetworkEpoch),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static LocalSendRoute fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LocalSendRoute>(map);
  }

  static LocalSendRoute deserialize(String json) {
    return ensureInitialized().decodeJson<LocalSendRoute>(json);
  }
}

mixin LocalSendRouteMappable {
  String serialize() {
    return LocalSendRouteMapper.ensureInitialized().encodeJson<LocalSendRoute>(
      this as LocalSendRoute,
    );
  }

  Map<String, dynamic> toJson() {
    return LocalSendRouteMapper.ensureInitialized().encodeMap<LocalSendRoute>(
      this as LocalSendRoute,
    );
  }

  LocalSendRouteCopyWith<LocalSendRoute, LocalSendRoute, LocalSendRoute>
  get copyWith => _LocalSendRouteCopyWithImpl<LocalSendRoute, LocalSendRoute>(
    this as LocalSendRoute,
    $identity,
    $identity,
  );
  @override
  String toString() {
    return LocalSendRouteMapper.ensureInitialized().stringifyValue(
      this as LocalSendRoute,
    );
  }

  @override
  bool operator ==(Object other) {
    return LocalSendRouteMapper.ensureInitialized().equalsValue(
      this as LocalSendRoute,
      other,
    );
  }

  @override
  int get hashCode {
    return LocalSendRouteMapper.ensureInitialized().hashValue(
      this as LocalSendRoute,
    );
  }
}

extension LocalSendRouteValueCopy<$R, $Out>
    on ObjectCopyWith<$R, LocalSendRoute, $Out> {
  LocalSendRouteCopyWith<$R, LocalSendRoute, $Out> get $asLocalSendRoute =>
      $base.as((v, t, t2) => _LocalSendRouteCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class LocalSendRouteCopyWith<$R, $In extends LocalSendRoute, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? interfaceName,
    String? localAddress,
    String? androidNetworkHandle,
    String? androidNetworkEpoch,
  });
  LocalSendRouteCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _LocalSendRouteCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, LocalSendRoute, $Out>
    implements LocalSendRouteCopyWith<$R, LocalSendRoute, $Out> {
  _LocalSendRouteCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<LocalSendRoute> $mapper =
      LocalSendRouteMapper.ensureInitialized();
  @override
  $R call({
    String? interfaceName,
    String? localAddress,
    Object? androidNetworkHandle = $none,
    Object? androidNetworkEpoch = $none,
  }) => $apply(
    FieldCopyWithData({
      if (interfaceName != null) #interfaceName: interfaceName,
      if (localAddress != null) #localAddress: localAddress,
      if (androidNetworkHandle != $none)
        #androidNetworkHandle: androidNetworkHandle,
      if (androidNetworkEpoch != $none)
        #androidNetworkEpoch: androidNetworkEpoch,
    }),
  );
  @override
  LocalSendRoute $make(CopyWithData data) => LocalSendRoute(
    interfaceName: data.get(#interfaceName, or: $value.interfaceName),
    localAddress: data.get(#localAddress, or: $value.localAddress),
    androidNetworkHandle: data.get(
      #androidNetworkHandle,
      or: $value.androidNetworkHandle,
    ),
    androidNetworkEpoch: data.get(
      #androidNetworkEpoch,
      or: $value.androidNetworkEpoch,
    ),
  );

  @override
  LocalSendRouteCopyWith<$R2, LocalSendRoute, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _LocalSendRouteCopyWithImpl<$R2, $Out2>($value, $cast, t);
}
