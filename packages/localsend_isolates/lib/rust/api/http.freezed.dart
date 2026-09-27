// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'http.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RsHttpClientError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsHttpClientError()';
}


}

/// @nodoc
class $RsHttpClientErrorCopyWith<$Res>  {
$RsHttpClientErrorCopyWith(RsHttpClientError _, $Res Function(RsHttpClientError) __);
}


/// Adds pattern-matching-related methods to [RsHttpClientError].
extension RsHttpClientErrorPatterns on RsHttpClientError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RsHttpClientError_StatusCode value)?  statusCode,TResult Function( RsHttpClientError_ResumeInterrupted value)?  resumeInterrupted,TResult Function( RsHttpClientError_Reqwest value)?  reqwest,TResult Function( RsHttpClientError_Json value)?  json,TResult Function( RsHttpClientError_Io value)?  io,TResult Function( RsHttpClientError_Other value)?  other,TResult Function( RsHttpClientError_Recovery value)?  recovery,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode() when statusCode != null:
return statusCode(_that);case RsHttpClientError_ResumeInterrupted() when resumeInterrupted != null:
return resumeInterrupted(_that);case RsHttpClientError_Reqwest() when reqwest != null:
return reqwest(_that);case RsHttpClientError_Json() when json != null:
return json(_that);case RsHttpClientError_Io() when io != null:
return io(_that);case RsHttpClientError_Other() when other != null:
return other(_that);case RsHttpClientError_Recovery() when recovery != null:
return recovery(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RsHttpClientError_StatusCode value)  statusCode,required TResult Function( RsHttpClientError_ResumeInterrupted value)  resumeInterrupted,required TResult Function( RsHttpClientError_Reqwest value)  reqwest,required TResult Function( RsHttpClientError_Json value)  json,required TResult Function( RsHttpClientError_Io value)  io,required TResult Function( RsHttpClientError_Other value)  other,required TResult Function( RsHttpClientError_Recovery value)  recovery,}){
final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode():
return statusCode(_that);case RsHttpClientError_ResumeInterrupted():
return resumeInterrupted(_that);case RsHttpClientError_Reqwest():
return reqwest(_that);case RsHttpClientError_Json():
return json(_that);case RsHttpClientError_Io():
return io(_that);case RsHttpClientError_Other():
return other(_that);case RsHttpClientError_Recovery():
return recovery(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RsHttpClientError_StatusCode value)?  statusCode,TResult? Function( RsHttpClientError_ResumeInterrupted value)?  resumeInterrupted,TResult? Function( RsHttpClientError_Reqwest value)?  reqwest,TResult? Function( RsHttpClientError_Json value)?  json,TResult? Function( RsHttpClientError_Io value)?  io,TResult? Function( RsHttpClientError_Other value)?  other,TResult? Function( RsHttpClientError_Recovery value)?  recovery,}){
final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode() when statusCode != null:
return statusCode(_that);case RsHttpClientError_ResumeInterrupted() when resumeInterrupted != null:
return resumeInterrupted(_that);case RsHttpClientError_Reqwest() when reqwest != null:
return reqwest(_that);case RsHttpClientError_Json() when json != null:
return json(_that);case RsHttpClientError_Io() when io != null:
return io(_that);case RsHttpClientError_Other() when other != null:
return other(_that);case RsHttpClientError_Recovery() when recovery != null:
return recovery(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( int status,  String? message)?  statusCode,TResult Function( bool retainedConfirmed)?  resumeInterrupted,TResult Function( String field0)?  reqwest,TResult Function( String field0)?  json,TResult Function( String field0)?  io,TResult Function( String field0)?  other,TResult Function( RsRecoveryFailureKind kind,  RsRecoveryRetention retention,  int? status)?  recovery,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode() when statusCode != null:
return statusCode(_that.status,_that.message);case RsHttpClientError_ResumeInterrupted() when resumeInterrupted != null:
return resumeInterrupted(_that.retainedConfirmed);case RsHttpClientError_Reqwest() when reqwest != null:
return reqwest(_that.field0);case RsHttpClientError_Json() when json != null:
return json(_that.field0);case RsHttpClientError_Io() when io != null:
return io(_that.field0);case RsHttpClientError_Other() when other != null:
return other(_that.field0);case RsHttpClientError_Recovery() when recovery != null:
return recovery(_that.kind,_that.retention,_that.status);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( int status,  String? message)  statusCode,required TResult Function( bool retainedConfirmed)  resumeInterrupted,required TResult Function( String field0)  reqwest,required TResult Function( String field0)  json,required TResult Function( String field0)  io,required TResult Function( String field0)  other,required TResult Function( RsRecoveryFailureKind kind,  RsRecoveryRetention retention,  int? status)  recovery,}) {final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode():
return statusCode(_that.status,_that.message);case RsHttpClientError_ResumeInterrupted():
return resumeInterrupted(_that.retainedConfirmed);case RsHttpClientError_Reqwest():
return reqwest(_that.field0);case RsHttpClientError_Json():
return json(_that.field0);case RsHttpClientError_Io():
return io(_that.field0);case RsHttpClientError_Other():
return other(_that.field0);case RsHttpClientError_Recovery():
return recovery(_that.kind,_that.retention,_that.status);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( int status,  String? message)?  statusCode,TResult? Function( bool retainedConfirmed)?  resumeInterrupted,TResult? Function( String field0)?  reqwest,TResult? Function( String field0)?  json,TResult? Function( String field0)?  io,TResult? Function( String field0)?  other,TResult? Function( RsRecoveryFailureKind kind,  RsRecoveryRetention retention,  int? status)?  recovery,}) {final _that = this;
switch (_that) {
case RsHttpClientError_StatusCode() when statusCode != null:
return statusCode(_that.status,_that.message);case RsHttpClientError_ResumeInterrupted() when resumeInterrupted != null:
return resumeInterrupted(_that.retainedConfirmed);case RsHttpClientError_Reqwest() when reqwest != null:
return reqwest(_that.field0);case RsHttpClientError_Json() when json != null:
return json(_that.field0);case RsHttpClientError_Io() when io != null:
return io(_that.field0);case RsHttpClientError_Other() when other != null:
return other(_that.field0);case RsHttpClientError_Recovery() when recovery != null:
return recovery(_that.kind,_that.retention,_that.status);case _:
  return null;

}
}

}

/// @nodoc


class RsHttpClientError_StatusCode extends RsHttpClientError {
  const RsHttpClientError_StatusCode({required this.status, this.message}): super._();


 final  int status;
 final  String? message;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_StatusCodeCopyWith<RsHttpClientError_StatusCode> get copyWith => _$RsHttpClientError_StatusCodeCopyWithImpl<RsHttpClientError_StatusCode>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_StatusCode&&(identical(other.status, status) || other.status == status)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,status,message);

@override
String toString() {
  return 'RsHttpClientError.statusCode(status: $status, message: $message)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_StatusCodeCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_StatusCodeCopyWith(RsHttpClientError_StatusCode value, $Res Function(RsHttpClientError_StatusCode) _then) = _$RsHttpClientError_StatusCodeCopyWithImpl;
@useResult
$Res call({
 int status, String? message
});




}
/// @nodoc
class _$RsHttpClientError_StatusCodeCopyWithImpl<$Res>
    implements $RsHttpClientError_StatusCodeCopyWith<$Res> {
  _$RsHttpClientError_StatusCodeCopyWithImpl(this._self, this._then);

  final RsHttpClientError_StatusCode _self;
  final $Res Function(RsHttpClientError_StatusCode) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? status = null,Object? message = freezed,}) {
  return _then(RsHttpClientError_StatusCode(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as int,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class RsHttpClientError_ResumeInterrupted extends RsHttpClientError {
  const RsHttpClientError_ResumeInterrupted({required this.retainedConfirmed}): super._();


 final  bool retainedConfirmed;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_ResumeInterruptedCopyWith<RsHttpClientError_ResumeInterrupted> get copyWith => _$RsHttpClientError_ResumeInterruptedCopyWithImpl<RsHttpClientError_ResumeInterrupted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_ResumeInterrupted&&(identical(other.retainedConfirmed, retainedConfirmed) || other.retainedConfirmed == retainedConfirmed));
}


@override
int get hashCode => Object.hash(runtimeType,retainedConfirmed);

@override
String toString() {
  return 'RsHttpClientError.resumeInterrupted(retainedConfirmed: $retainedConfirmed)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_ResumeInterruptedCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_ResumeInterruptedCopyWith(RsHttpClientError_ResumeInterrupted value, $Res Function(RsHttpClientError_ResumeInterrupted) _then) = _$RsHttpClientError_ResumeInterruptedCopyWithImpl;
@useResult
$Res call({
 bool retainedConfirmed
});




}
/// @nodoc
class _$RsHttpClientError_ResumeInterruptedCopyWithImpl<$Res>
    implements $RsHttpClientError_ResumeInterruptedCopyWith<$Res> {
  _$RsHttpClientError_ResumeInterruptedCopyWithImpl(this._self, this._then);

  final RsHttpClientError_ResumeInterrupted _self;
  final $Res Function(RsHttpClientError_ResumeInterrupted) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? retainedConfirmed = null,}) {
  return _then(RsHttpClientError_ResumeInterrupted(
retainedConfirmed: null == retainedConfirmed ? _self.retainedConfirmed : retainedConfirmed // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RsHttpClientError_Reqwest extends RsHttpClientError {
  const RsHttpClientError_Reqwest(this.field0): super._();


 final  String field0;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_ReqwestCopyWith<RsHttpClientError_Reqwest> get copyWith => _$RsHttpClientError_ReqwestCopyWithImpl<RsHttpClientError_Reqwest>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_Reqwest&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'RsHttpClientError.reqwest(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_ReqwestCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_ReqwestCopyWith(RsHttpClientError_Reqwest value, $Res Function(RsHttpClientError_Reqwest) _then) = _$RsHttpClientError_ReqwestCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RsHttpClientError_ReqwestCopyWithImpl<$Res>
    implements $RsHttpClientError_ReqwestCopyWith<$Res> {
  _$RsHttpClientError_ReqwestCopyWithImpl(this._self, this._then);

  final RsHttpClientError_Reqwest _self;
  final $Res Function(RsHttpClientError_Reqwest) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RsHttpClientError_Reqwest(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsHttpClientError_Json extends RsHttpClientError {
  const RsHttpClientError_Json(this.field0): super._();


 final  String field0;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_JsonCopyWith<RsHttpClientError_Json> get copyWith => _$RsHttpClientError_JsonCopyWithImpl<RsHttpClientError_Json>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_Json&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'RsHttpClientError.json(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_JsonCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_JsonCopyWith(RsHttpClientError_Json value, $Res Function(RsHttpClientError_Json) _then) = _$RsHttpClientError_JsonCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RsHttpClientError_JsonCopyWithImpl<$Res>
    implements $RsHttpClientError_JsonCopyWith<$Res> {
  _$RsHttpClientError_JsonCopyWithImpl(this._self, this._then);

  final RsHttpClientError_Json _self;
  final $Res Function(RsHttpClientError_Json) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RsHttpClientError_Json(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsHttpClientError_Io extends RsHttpClientError {
  const RsHttpClientError_Io(this.field0): super._();


 final  String field0;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_IoCopyWith<RsHttpClientError_Io> get copyWith => _$RsHttpClientError_IoCopyWithImpl<RsHttpClientError_Io>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_Io&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'RsHttpClientError.io(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_IoCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_IoCopyWith(RsHttpClientError_Io value, $Res Function(RsHttpClientError_Io) _then) = _$RsHttpClientError_IoCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RsHttpClientError_IoCopyWithImpl<$Res>
    implements $RsHttpClientError_IoCopyWith<$Res> {
  _$RsHttpClientError_IoCopyWithImpl(this._self, this._then);

  final RsHttpClientError_Io _self;
  final $Res Function(RsHttpClientError_Io) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RsHttpClientError_Io(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsHttpClientError_Other extends RsHttpClientError {
  const RsHttpClientError_Other(this.field0): super._();


 final  String field0;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_OtherCopyWith<RsHttpClientError_Other> get copyWith => _$RsHttpClientError_OtherCopyWithImpl<RsHttpClientError_Other>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_Other&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'RsHttpClientError.other(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_OtherCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_OtherCopyWith(RsHttpClientError_Other value, $Res Function(RsHttpClientError_Other) _then) = _$RsHttpClientError_OtherCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$RsHttpClientError_OtherCopyWithImpl<$Res>
    implements $RsHttpClientError_OtherCopyWith<$Res> {
  _$RsHttpClientError_OtherCopyWithImpl(this._self, this._then);

  final RsHttpClientError_Other _self;
  final $Res Function(RsHttpClientError_Other) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(RsHttpClientError_Other(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsHttpClientError_Recovery extends RsHttpClientError {
  const RsHttpClientError_Recovery({required this.kind, required this.retention, this.status}): super._();


 final  RsRecoveryFailureKind kind;
 final  RsRecoveryRetention retention;
 final  int? status;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsHttpClientError_RecoveryCopyWith<RsHttpClientError_Recovery> get copyWith => _$RsHttpClientError_RecoveryCopyWithImpl<RsHttpClientError_Recovery>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsHttpClientError_Recovery&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.retention, retention) || other.retention == retention)&&(identical(other.status, status) || other.status == status));
}


@override
int get hashCode => Object.hash(runtimeType,kind,retention,status);

@override
String toString() {
  return 'RsHttpClientError.recovery(kind: $kind, retention: $retention, status: $status)';
}


}

/// @nodoc
abstract mixin class $RsHttpClientError_RecoveryCopyWith<$Res> implements $RsHttpClientErrorCopyWith<$Res> {
  factory $RsHttpClientError_RecoveryCopyWith(RsHttpClientError_Recovery value, $Res Function(RsHttpClientError_Recovery) _then) = _$RsHttpClientError_RecoveryCopyWithImpl;
@useResult
$Res call({
 RsRecoveryFailureKind kind, RsRecoveryRetention retention, int? status
});




}
/// @nodoc
class _$RsHttpClientError_RecoveryCopyWithImpl<$Res>
    implements $RsHttpClientError_RecoveryCopyWith<$Res> {
  _$RsHttpClientError_RecoveryCopyWithImpl(this._self, this._then);

  final RsHttpClientError_Recovery _self;
  final $Res Function(RsHttpClientError_Recovery) _then;

/// Create a copy of RsHttpClientError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? kind = null,Object? retention = null,Object? status = freezed,}) {
  return _then(RsHttpClientError_Recovery(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as RsRecoveryFailureKind,retention: null == retention ? _self.retention : retention // ignore: cast_nullable_to_non_nullable
as RsRecoveryRetention,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

/// @nodoc
mixin _$RsUploadEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsUploadEvent()';
}


}

/// @nodoc
class $RsUploadEventCopyWith<$Res>  {
$RsUploadEventCopyWith(RsUploadEvent _, $Res Function(RsUploadEvent) __);
}


/// Adds pattern-matching-related methods to [RsUploadEvent].
extension RsUploadEventPatterns on RsUploadEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RsUploadEvent_SourceEndGrant value)?  sourceEndGrant,TResult Function( RsUploadEvent_SourceEndUnavailable value)?  sourceEndUnavailable,TResult Function( RsUploadEvent_Progress value)?  progress,TResult Function( RsUploadEvent_Verification value)?  verification,TResult Function( RsUploadEvent_Failed value)?  failed,TResult Function( RsUploadEvent_Recovery value)?  recovery,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant() when sourceEndGrant != null:
return sourceEndGrant(_that);case RsUploadEvent_SourceEndUnavailable() when sourceEndUnavailable != null:
return sourceEndUnavailable(_that);case RsUploadEvent_Progress() when progress != null:
return progress(_that);case RsUploadEvent_Verification() when verification != null:
return verification(_that);case RsUploadEvent_Failed() when failed != null:
return failed(_that);case RsUploadEvent_Recovery() when recovery != null:
return recovery(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RsUploadEvent_SourceEndGrant value)  sourceEndGrant,required TResult Function( RsUploadEvent_SourceEndUnavailable value)  sourceEndUnavailable,required TResult Function( RsUploadEvent_Progress value)  progress,required TResult Function( RsUploadEvent_Verification value)  verification,required TResult Function( RsUploadEvent_Failed value)  failed,required TResult Function( RsUploadEvent_Recovery value)  recovery,}){
final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant():
return sourceEndGrant(_that);case RsUploadEvent_SourceEndUnavailable():
return sourceEndUnavailable(_that);case RsUploadEvent_Progress():
return progress(_that);case RsUploadEvent_Verification():
return verification(_that);case RsUploadEvent_Failed():
return failed(_that);case RsUploadEvent_Recovery():
return recovery(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RsUploadEvent_SourceEndGrant value)?  sourceEndGrant,TResult? Function( RsUploadEvent_SourceEndUnavailable value)?  sourceEndUnavailable,TResult? Function( RsUploadEvent_Progress value)?  progress,TResult? Function( RsUploadEvent_Verification value)?  verification,TResult? Function( RsUploadEvent_Failed value)?  failed,TResult? Function( RsUploadEvent_Recovery value)?  recovery,}){
final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant() when sourceEndGrant != null:
return sourceEndGrant(_that);case RsUploadEvent_SourceEndUnavailable() when sourceEndUnavailable != null:
return sourceEndUnavailable(_that);case RsUploadEvent_Progress() when progress != null:
return progress(_that);case RsUploadEvent_Verification() when verification != null:
return verification(_that);case RsUploadEvent_Failed() when failed != null:
return failed(_that);case RsUploadEvent_Recovery() when recovery != null:
return recovery(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String ackId,  RsSourceEndGrant grant)?  sourceEndGrant,TResult Function()?  sourceEndUnavailable,TResult Function( double progress)?  progress,TResult Function( BigInt verifiedBytes,  BigInt totalBytes)?  verification,TResult Function( RsHttpClientError error)?  failed,TResult Function( bool waiting,  int attempt,  int retryAfterMs)?  recovery,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant() when sourceEndGrant != null:
return sourceEndGrant(_that.ackId,_that.grant);case RsUploadEvent_SourceEndUnavailable() when sourceEndUnavailable != null:
return sourceEndUnavailable();case RsUploadEvent_Progress() when progress != null:
return progress(_that.progress);case RsUploadEvent_Verification() when verification != null:
return verification(_that.verifiedBytes,_that.totalBytes);case RsUploadEvent_Failed() when failed != null:
return failed(_that.error);case RsUploadEvent_Recovery() when recovery != null:
return recovery(_that.waiting,_that.attempt,_that.retryAfterMs);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String ackId,  RsSourceEndGrant grant)  sourceEndGrant,required TResult Function()  sourceEndUnavailable,required TResult Function( double progress)  progress,required TResult Function( BigInt verifiedBytes,  BigInt totalBytes)  verification,required TResult Function( RsHttpClientError error)  failed,required TResult Function( bool waiting,  int attempt,  int retryAfterMs)  recovery,}) {final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant():
return sourceEndGrant(_that.ackId,_that.grant);case RsUploadEvent_SourceEndUnavailable():
return sourceEndUnavailable();case RsUploadEvent_Progress():
return progress(_that.progress);case RsUploadEvent_Verification():
return verification(_that.verifiedBytes,_that.totalBytes);case RsUploadEvent_Failed():
return failed(_that.error);case RsUploadEvent_Recovery():
return recovery(_that.waiting,_that.attempt,_that.retryAfterMs);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String ackId,  RsSourceEndGrant grant)?  sourceEndGrant,TResult? Function()?  sourceEndUnavailable,TResult? Function( double progress)?  progress,TResult? Function( BigInt verifiedBytes,  BigInt totalBytes)?  verification,TResult? Function( RsHttpClientError error)?  failed,TResult? Function( bool waiting,  int attempt,  int retryAfterMs)?  recovery,}) {final _that = this;
switch (_that) {
case RsUploadEvent_SourceEndGrant() when sourceEndGrant != null:
return sourceEndGrant(_that.ackId,_that.grant);case RsUploadEvent_SourceEndUnavailable() when sourceEndUnavailable != null:
return sourceEndUnavailable();case RsUploadEvent_Progress() when progress != null:
return progress(_that.progress);case RsUploadEvent_Verification() when verification != null:
return verification(_that.verifiedBytes,_that.totalBytes);case RsUploadEvent_Failed() when failed != null:
return failed(_that.error);case RsUploadEvent_Recovery() when recovery != null:
return recovery(_that.waiting,_that.attempt,_that.retryAfterMs);case _:
  return null;

}
}

}

/// @nodoc


class RsUploadEvent_SourceEndGrant extends RsUploadEvent {
  const RsUploadEvent_SourceEndGrant({required this.ackId, required this.grant}): super._();


 final  String ackId;
 final  RsSourceEndGrant grant;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsUploadEvent_SourceEndGrantCopyWith<RsUploadEvent_SourceEndGrant> get copyWith => _$RsUploadEvent_SourceEndGrantCopyWithImpl<RsUploadEvent_SourceEndGrant>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_SourceEndGrant&&(identical(other.ackId, ackId) || other.ackId == ackId)&&(identical(other.grant, grant) || other.grant == grant));
}


@override
int get hashCode => Object.hash(runtimeType,ackId,grant);

@override
String toString() {
  return 'RsUploadEvent.sourceEndGrant(ackId: $ackId, grant: $grant)';
}


}

/// @nodoc
abstract mixin class $RsUploadEvent_SourceEndGrantCopyWith<$Res> implements $RsUploadEventCopyWith<$Res> {
  factory $RsUploadEvent_SourceEndGrantCopyWith(RsUploadEvent_SourceEndGrant value, $Res Function(RsUploadEvent_SourceEndGrant) _then) = _$RsUploadEvent_SourceEndGrantCopyWithImpl;
@useResult
$Res call({
 String ackId, RsSourceEndGrant grant
});




}
/// @nodoc
class _$RsUploadEvent_SourceEndGrantCopyWithImpl<$Res>
    implements $RsUploadEvent_SourceEndGrantCopyWith<$Res> {
  _$RsUploadEvent_SourceEndGrantCopyWithImpl(this._self, this._then);

  final RsUploadEvent_SourceEndGrant _self;
  final $Res Function(RsUploadEvent_SourceEndGrant) _then;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ackId = null,Object? grant = null,}) {
  return _then(RsUploadEvent_SourceEndGrant(
ackId: null == ackId ? _self.ackId : ackId // ignore: cast_nullable_to_non_nullable
as String,grant: null == grant ? _self.grant : grant // ignore: cast_nullable_to_non_nullable
as RsSourceEndGrant,
  ));
}


}

/// @nodoc


class RsUploadEvent_SourceEndUnavailable extends RsUploadEvent {
  const RsUploadEvent_SourceEndUnavailable(): super._();







@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_SourceEndUnavailable);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsUploadEvent.sourceEndUnavailable()';
}


}




/// @nodoc


class RsUploadEvent_Progress extends RsUploadEvent {
  const RsUploadEvent_Progress({required this.progress}): super._();


 final  double progress;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsUploadEvent_ProgressCopyWith<RsUploadEvent_Progress> get copyWith => _$RsUploadEvent_ProgressCopyWithImpl<RsUploadEvent_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_Progress&&(identical(other.progress, progress) || other.progress == progress));
}


@override
int get hashCode => Object.hash(runtimeType,progress);

@override
String toString() {
  return 'RsUploadEvent.progress(progress: $progress)';
}


}

/// @nodoc
abstract mixin class $RsUploadEvent_ProgressCopyWith<$Res> implements $RsUploadEventCopyWith<$Res> {
  factory $RsUploadEvent_ProgressCopyWith(RsUploadEvent_Progress value, $Res Function(RsUploadEvent_Progress) _then) = _$RsUploadEvent_ProgressCopyWithImpl;
@useResult
$Res call({
 double progress
});




}
/// @nodoc
class _$RsUploadEvent_ProgressCopyWithImpl<$Res>
    implements $RsUploadEvent_ProgressCopyWith<$Res> {
  _$RsUploadEvent_ProgressCopyWithImpl(this._self, this._then);

  final RsUploadEvent_Progress _self;
  final $Res Function(RsUploadEvent_Progress) _then;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? progress = null,}) {
  return _then(RsUploadEvent_Progress(
progress: null == progress ? _self.progress : progress // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class RsUploadEvent_Verification extends RsUploadEvent {
  const RsUploadEvent_Verification({required this.verifiedBytes, required this.totalBytes}): super._();


 final  BigInt verifiedBytes;
 final  BigInt totalBytes;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsUploadEvent_VerificationCopyWith<RsUploadEvent_Verification> get copyWith => _$RsUploadEvent_VerificationCopyWithImpl<RsUploadEvent_Verification>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_Verification&&(identical(other.verifiedBytes, verifiedBytes) || other.verifiedBytes == verifiedBytes)&&(identical(other.totalBytes, totalBytes) || other.totalBytes == totalBytes));
}


@override
int get hashCode => Object.hash(runtimeType,verifiedBytes,totalBytes);

@override
String toString() {
  return 'RsUploadEvent.verification(verifiedBytes: $verifiedBytes, totalBytes: $totalBytes)';
}


}

/// @nodoc
abstract mixin class $RsUploadEvent_VerificationCopyWith<$Res> implements $RsUploadEventCopyWith<$Res> {
  factory $RsUploadEvent_VerificationCopyWith(RsUploadEvent_Verification value, $Res Function(RsUploadEvent_Verification) _then) = _$RsUploadEvent_VerificationCopyWithImpl;
@useResult
$Res call({
 BigInt verifiedBytes, BigInt totalBytes
});




}
/// @nodoc
class _$RsUploadEvent_VerificationCopyWithImpl<$Res>
    implements $RsUploadEvent_VerificationCopyWith<$Res> {
  _$RsUploadEvent_VerificationCopyWithImpl(this._self, this._then);

  final RsUploadEvent_Verification _self;
  final $Res Function(RsUploadEvent_Verification) _then;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? verifiedBytes = null,Object? totalBytes = null,}) {
  return _then(RsUploadEvent_Verification(
verifiedBytes: null == verifiedBytes ? _self.verifiedBytes : verifiedBytes // ignore: cast_nullable_to_non_nullable
as BigInt,totalBytes: null == totalBytes ? _self.totalBytes : totalBytes // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class RsUploadEvent_Failed extends RsUploadEvent {
  const RsUploadEvent_Failed({required this.error}): super._();


 final  RsHttpClientError error;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsUploadEvent_FailedCopyWith<RsUploadEvent_Failed> get copyWith => _$RsUploadEvent_FailedCopyWithImpl<RsUploadEvent_Failed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_Failed&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,error);

@override
String toString() {
  return 'RsUploadEvent.failed(error: $error)';
}


}

/// @nodoc
abstract mixin class $RsUploadEvent_FailedCopyWith<$Res> implements $RsUploadEventCopyWith<$Res> {
  factory $RsUploadEvent_FailedCopyWith(RsUploadEvent_Failed value, $Res Function(RsUploadEvent_Failed) _then) = _$RsUploadEvent_FailedCopyWithImpl;
@useResult
$Res call({
 RsHttpClientError error
});


$RsHttpClientErrorCopyWith<$Res> get error;

}
/// @nodoc
class _$RsUploadEvent_FailedCopyWithImpl<$Res>
    implements $RsUploadEvent_FailedCopyWith<$Res> {
  _$RsUploadEvent_FailedCopyWithImpl(this._self, this._then);

  final RsUploadEvent_Failed _self;
  final $Res Function(RsUploadEvent_Failed) _then;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? error = null,}) {
  return _then(RsUploadEvent_Failed(
error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as RsHttpClientError,
  ));
}

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$RsHttpClientErrorCopyWith<$Res> get error {

  return $RsHttpClientErrorCopyWith<$Res>(_self.error, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}

/// @nodoc


class RsUploadEvent_Recovery extends RsUploadEvent {
  const RsUploadEvent_Recovery({required this.waiting, required this.attempt, required this.retryAfterMs}): super._();


 final  bool waiting;
 final  int attempt;
 final  int retryAfterMs;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsUploadEvent_RecoveryCopyWith<RsUploadEvent_Recovery> get copyWith => _$RsUploadEvent_RecoveryCopyWithImpl<RsUploadEvent_Recovery>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsUploadEvent_Recovery&&(identical(other.waiting, waiting) || other.waiting == waiting)&&(identical(other.attempt, attempt) || other.attempt == attempt)&&(identical(other.retryAfterMs, retryAfterMs) || other.retryAfterMs == retryAfterMs));
}


@override
int get hashCode => Object.hash(runtimeType,waiting,attempt,retryAfterMs);

@override
String toString() {
  return 'RsUploadEvent.recovery(waiting: $waiting, attempt: $attempt, retryAfterMs: $retryAfterMs)';
}


}

/// @nodoc
abstract mixin class $RsUploadEvent_RecoveryCopyWith<$Res> implements $RsUploadEventCopyWith<$Res> {
  factory $RsUploadEvent_RecoveryCopyWith(RsUploadEvent_Recovery value, $Res Function(RsUploadEvent_Recovery) _then) = _$RsUploadEvent_RecoveryCopyWithImpl;
@useResult
$Res call({
 bool waiting, int attempt, int retryAfterMs
});




}
/// @nodoc
class _$RsUploadEvent_RecoveryCopyWithImpl<$Res>
    implements $RsUploadEvent_RecoveryCopyWith<$Res> {
  _$RsUploadEvent_RecoveryCopyWithImpl(this._self, this._then);

  final RsUploadEvent_Recovery _self;
  final $Res Function(RsUploadEvent_Recovery) _then;

/// Create a copy of RsUploadEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? waiting = null,Object? attempt = null,Object? retryAfterMs = null,}) {
  return _then(RsUploadEvent_Recovery(
waiting: null == waiting ? _self.waiting : waiting // ignore: cast_nullable_to_non_nullable
as bool,attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,retryAfterMs: null == retryAfterMs ? _self.retryAfterMs : retryAfterMs // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
