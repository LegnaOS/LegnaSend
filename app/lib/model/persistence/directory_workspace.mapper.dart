// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'directory_workspace.dart';

class WorkspaceSourceKindMapper extends EnumMapper<WorkspaceSourceKind> {
  WorkspaceSourceKindMapper._();

  static WorkspaceSourceKindMapper? _instance;
  static WorkspaceSourceKindMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WorkspaceSourceKindMapper._());
    }
    return _instance!;
  }

  static WorkspaceSourceKind fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  WorkspaceSourceKind decode(dynamic value) {
    switch (value) {
      case r'directory':
        return WorkspaceSourceKind.directory;
      case r'androidTree':
        return WorkspaceSourceKind.androidTree;
      case r'appleBookmark':
        return WorkspaceSourceKind.appleBookmark;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(WorkspaceSourceKind self) {
    switch (self) {
      case WorkspaceSourceKind.directory:
        return r'directory';
      case WorkspaceSourceKind.androidTree:
        return r'androidTree';
      case WorkspaceSourceKind.appleBookmark:
        return r'appleBookmark';
    }
  }
}

extension WorkspaceSourceKindMapperExtension on WorkspaceSourceKind {
  String toValue() {
    WorkspaceSourceKindMapper.ensureInitialized();
    return MapperContainer.globals.toValue<WorkspaceSourceKind>(this) as String;
  }
}

class WorkspaceInvalidReasonMapper extends EnumMapper<WorkspaceInvalidReason> {
  WorkspaceInvalidReasonMapper._();

  static WorkspaceInvalidReasonMapper? _instance;
  static WorkspaceInvalidReasonMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WorkspaceInvalidReasonMapper._());
    }
    return _instance!;
  }

  static WorkspaceInvalidReason fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  WorkspaceInvalidReason decode(dynamic value) {
    switch (value) {
      case r'missing':
        return WorkspaceInvalidReason.missing;
      case r'notDirectory':
        return WorkspaceInvalidReason.notDirectory;
      case r'permissionDenied':
        return WorkspaceInvalidReason.permissionDenied;
      case r'grantUnavailable':
        return WorkspaceInvalidReason.grantUnavailable;
      case r'ioError':
        return WorkspaceInvalidReason.ioError;
      case r'timeout':
        return WorkspaceInvalidReason.timeout;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(WorkspaceInvalidReason self) {
    switch (self) {
      case WorkspaceInvalidReason.missing:
        return r'missing';
      case WorkspaceInvalidReason.notDirectory:
        return r'notDirectory';
      case WorkspaceInvalidReason.permissionDenied:
        return r'permissionDenied';
      case WorkspaceInvalidReason.grantUnavailable:
        return r'grantUnavailable';
      case WorkspaceInvalidReason.ioError:
        return r'ioError';
      case WorkspaceInvalidReason.timeout:
        return r'timeout';
    }
  }
}

extension WorkspaceInvalidReasonMapperExtension on WorkspaceInvalidReason {
  String toValue() {
    WorkspaceInvalidReasonMapper.ensureInitialized();
    return MapperContainer.globals.toValue<WorkspaceInvalidReason>(this)
        as String;
  }
}

class WorkspaceSourceMapper extends ClassMapperBase<WorkspaceSource> {
  WorkspaceSourceMapper._();

  static WorkspaceSourceMapper? _instance;
  static WorkspaceSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WorkspaceSourceMapper._());
      WorkspaceSourceKindMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'WorkspaceSource';

  static WorkspaceSourceKind _$kind(WorkspaceSource v) => v.kind;
  static const Field<WorkspaceSource, WorkspaceSourceKind> _f$kind = Field(
    'kind',
    _$kind,
  );
  static String _$locator(WorkspaceSource v) => v.locator;
  static const Field<WorkspaceSource, String> _f$locator = Field(
    'locator',
    _$locator,
  );
  static String? _$grantId(WorkspaceSource v) => v.grantId;
  static const Field<WorkspaceSource, String> _f$grantId = Field(
    'grantId',
    _$grantId,
    opt: true,
  );

  @override
  final MappableFields<WorkspaceSource> fields = const {
    #kind: _f$kind,
    #locator: _f$locator,
    #grantId: _f$grantId,
  };

  static WorkspaceSource _instantiate(DecodingData data) {
    return WorkspaceSource(
      kind: data.dec(_f$kind),
      locator: data.dec(_f$locator),
      grantId: data.dec(_f$grantId),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static WorkspaceSource fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<WorkspaceSource>(map);
  }

  static WorkspaceSource deserialize(String json) {
    return ensureInitialized().decodeJson<WorkspaceSource>(json);
  }
}

mixin WorkspaceSourceMappable {
  String serialize() {
    return WorkspaceSourceMapper.ensureInitialized()
        .encodeJson<WorkspaceSource>(this as WorkspaceSource);
  }

  Map<String, dynamic> toJson() {
    return WorkspaceSourceMapper.ensureInitialized().encodeMap<WorkspaceSource>(
      this as WorkspaceSource,
    );
  }

  WorkspaceSourceCopyWith<WorkspaceSource, WorkspaceSource, WorkspaceSource>
  get copyWith =>
      _WorkspaceSourceCopyWithImpl<WorkspaceSource, WorkspaceSource>(
        this as WorkspaceSource,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return WorkspaceSourceMapper.ensureInitialized().stringifyValue(
      this as WorkspaceSource,
    );
  }

  @override
  bool operator ==(Object other) {
    return WorkspaceSourceMapper.ensureInitialized().equalsValue(
      this as WorkspaceSource,
      other,
    );
  }

  @override
  int get hashCode {
    return WorkspaceSourceMapper.ensureInitialized().hashValue(
      this as WorkspaceSource,
    );
  }
}

extension WorkspaceSourceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, WorkspaceSource, $Out> {
  WorkspaceSourceCopyWith<$R, WorkspaceSource, $Out> get $asWorkspaceSource =>
      $base.as((v, t, t2) => _WorkspaceSourceCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class WorkspaceSourceCopyWith<$R, $In extends WorkspaceSource, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({WorkspaceSourceKind? kind, String? locator, String? grantId});
  WorkspaceSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _WorkspaceSourceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, WorkspaceSource, $Out>
    implements WorkspaceSourceCopyWith<$R, WorkspaceSource, $Out> {
  _WorkspaceSourceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<WorkspaceSource> $mapper =
      WorkspaceSourceMapper.ensureInitialized();
  @override
  $R call({
    WorkspaceSourceKind? kind,
    String? locator,
    Object? grantId = $none,
  }) => $apply(
    FieldCopyWithData({
      if (kind != null) #kind: kind,
      if (locator != null) #locator: locator,
      if (grantId != $none) #grantId: grantId,
    }),
  );
  @override
  WorkspaceSource $make(CopyWithData data) => WorkspaceSource(
    kind: data.get(#kind, or: $value.kind),
    locator: data.get(#locator, or: $value.locator),
    grantId: data.get(#grantId, or: $value.grantId),
  );

  @override
  WorkspaceSourceCopyWith<$R2, WorkspaceSource, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _WorkspaceSourceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class DirectoryWorkspaceMapper extends ClassMapperBase<DirectoryWorkspace> {
  DirectoryWorkspaceMapper._();

  static DirectoryWorkspaceMapper? _instance;
  static DirectoryWorkspaceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DirectoryWorkspaceMapper._());
      WorkspaceSourceMapper.ensureInitialized();
      WorkspaceInvalidReasonMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'DirectoryWorkspace';

  static String _$id(DirectoryWorkspace v) => v.id;
  static const Field<DirectoryWorkspace, String> _f$id = Field('id', _$id);
  static String _$name(DirectoryWorkspace v) => v.name;
  static const Field<DirectoryWorkspace, String> _f$name = Field(
    'name',
    _$name,
  );
  static String _$slug(DirectoryWorkspace v) => v.slug;
  static const Field<DirectoryWorkspace, String> _f$slug = Field(
    'slug',
    _$slug,
  );
  static WorkspaceSource _$source(DirectoryWorkspace v) => v.source;
  static const Field<DirectoryWorkspace, WorkspaceSource> _f$source = Field(
    'source',
    _$source,
  );
  static bool _$enabled(DirectoryWorkspace v) => v.enabled;
  static const Field<DirectoryWorkspace, bool> _f$enabled = Field(
    'enabled',
    _$enabled,
  );
  static bool _$visible(DirectoryWorkspace v) => v.visible;
  static const Field<DirectoryWorkspace, bool> _f$visible = Field(
    'visible',
    _$visible,
  );
  static int _$generation(DirectoryWorkspace v) => v.generation;
  static const Field<DirectoryWorkspace, int> _f$generation = Field(
    'generation',
    _$generation,
  );
  static WorkspaceInvalidReason? _$invalidReason(DirectoryWorkspace v) =>
      v.invalidReason;
  static const Field<DirectoryWorkspace, WorkspaceInvalidReason>
  _f$invalidReason = Field('invalidReason', _$invalidReason, opt: true);
  static String? _$passwordHash(DirectoryWorkspace v) => v.passwordHash;
  static const Field<DirectoryWorkspace, String> _f$passwordHash = Field(
    'passwordHash',
    _$passwordHash,
    opt: true,
  );
  static bool _$allowUpload(DirectoryWorkspace v) => v.allowUpload;
  static const Field<DirectoryWorkspace, bool> _f$allowUpload = Field(
    'allowUpload',
    _$allowUpload,
    opt: true,
    def: false,
  );

  @override
  final MappableFields<DirectoryWorkspace> fields = const {
    #id: _f$id,
    #name: _f$name,
    #slug: _f$slug,
    #source: _f$source,
    #enabled: _f$enabled,
    #visible: _f$visible,
    #generation: _f$generation,
    #invalidReason: _f$invalidReason,
    #passwordHash: _f$passwordHash,
    #allowUpload: _f$allowUpload,
  };

  static DirectoryWorkspace _instantiate(DecodingData data) {
    return DirectoryWorkspace(
      id: data.dec(_f$id),
      name: data.dec(_f$name),
      slug: data.dec(_f$slug),
      source: data.dec(_f$source),
      enabled: data.dec(_f$enabled),
      visible: data.dec(_f$visible),
      generation: data.dec(_f$generation),
      invalidReason: data.dec(_f$invalidReason),
      passwordHash: data.dec(_f$passwordHash),
      allowUpload: data.dec(_f$allowUpload),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static DirectoryWorkspace fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<DirectoryWorkspace>(map);
  }

  static DirectoryWorkspace deserialize(String json) {
    return ensureInitialized().decodeJson<DirectoryWorkspace>(json);
  }
}

mixin DirectoryWorkspaceMappable {
  String serialize() {
    return DirectoryWorkspaceMapper.ensureInitialized()
        .encodeJson<DirectoryWorkspace>(this as DirectoryWorkspace);
  }

  Map<String, dynamic> toJson() {
    return DirectoryWorkspaceMapper.ensureInitialized()
        .encodeMap<DirectoryWorkspace>(this as DirectoryWorkspace);
  }

  DirectoryWorkspaceCopyWith<
    DirectoryWorkspace,
    DirectoryWorkspace,
    DirectoryWorkspace
  >
  get copyWith =>
      _DirectoryWorkspaceCopyWithImpl<DirectoryWorkspace, DirectoryWorkspace>(
        this as DirectoryWorkspace,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return DirectoryWorkspaceMapper.ensureInitialized().stringifyValue(
      this as DirectoryWorkspace,
    );
  }

  @override
  bool operator ==(Object other) {
    return DirectoryWorkspaceMapper.ensureInitialized().equalsValue(
      this as DirectoryWorkspace,
      other,
    );
  }

  @override
  int get hashCode {
    return DirectoryWorkspaceMapper.ensureInitialized().hashValue(
      this as DirectoryWorkspace,
    );
  }
}

extension DirectoryWorkspaceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, DirectoryWorkspace, $Out> {
  DirectoryWorkspaceCopyWith<$R, DirectoryWorkspace, $Out>
  get $asDirectoryWorkspace => $base.as(
    (v, t, t2) => _DirectoryWorkspaceCopyWithImpl<$R, $Out>(v, t, t2),
  );
}

abstract class DirectoryWorkspaceCopyWith<
  $R,
  $In extends DirectoryWorkspace,
  $Out
>
    implements ClassCopyWith<$R, $In, $Out> {
  WorkspaceSourceCopyWith<$R, WorkspaceSource, WorkspaceSource> get source;
  $R call({
    String? id,
    String? name,
    String? slug,
    WorkspaceSource? source,
    bool? enabled,
    bool? visible,
    int? generation,
    WorkspaceInvalidReason? invalidReason,
    String? passwordHash,
    bool? allowUpload,
  });
  DirectoryWorkspaceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _DirectoryWorkspaceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, DirectoryWorkspace, $Out>
    implements DirectoryWorkspaceCopyWith<$R, DirectoryWorkspace, $Out> {
  _DirectoryWorkspaceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<DirectoryWorkspace> $mapper =
      DirectoryWorkspaceMapper.ensureInitialized();
  @override
  WorkspaceSourceCopyWith<$R, WorkspaceSource, WorkspaceSource> get source =>
      $value.source.copyWith.$chain((v) => call(source: v));
  @override
  $R call({
    String? id,
    String? name,
    String? slug,
    WorkspaceSource? source,
    bool? enabled,
    bool? visible,
    int? generation,
    Object? invalidReason = $none,
    Object? passwordHash = $none,
    bool? allowUpload,
  }) => $apply(
    FieldCopyWithData({
      if (id != null) #id: id,
      if (name != null) #name: name,
      if (slug != null) #slug: slug,
      if (source != null) #source: source,
      if (enabled != null) #enabled: enabled,
      if (visible != null) #visible: visible,
      if (generation != null) #generation: generation,
      if (invalidReason != $none) #invalidReason: invalidReason,
      if (passwordHash != $none) #passwordHash: passwordHash,
      if (allowUpload != null) #allowUpload: allowUpload,
    }),
  );
  @override
  DirectoryWorkspace $make(CopyWithData data) => DirectoryWorkspace(
    id: data.get(#id, or: $value.id),
    name: data.get(#name, or: $value.name),
    slug: data.get(#slug, or: $value.slug),
    source: data.get(#source, or: $value.source),
    enabled: data.get(#enabled, or: $value.enabled),
    visible: data.get(#visible, or: $value.visible),
    generation: data.get(#generation, or: $value.generation),
    invalidReason: data.get(#invalidReason, or: $value.invalidReason),
    passwordHash: data.get(#passwordHash, or: $value.passwordHash),
    allowUpload: data.get(#allowUpload, or: $value.allowUpload),
  );

  @override
  DirectoryWorkspaceCopyWith<$R2, DirectoryWorkspace, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _DirectoryWorkspaceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}
