// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RsServerEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsServerEvent()';
}


}

/// @nodoc
class $RsServerEventCopyWith<$Res>  {
$RsServerEventCopyWith(RsServerEvent _, $Res Function(RsServerEvent) __);
}


/// Adds pattern-matching-related methods to [RsServerEvent].
extension RsServerEventPatterns on RsServerEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RsServerEvent_ReceiveSourceEndScope value)?  receiveSourceEndScope,TResult Function( RsServerEvent_DirectoryContent value)?  directoryContent,TResult Function( RsServerEvent_WebDownloadActivity value)?  webDownloadActivity,TResult Function( RsServerEvent_DirectoryDocument value)?  directoryDocument,TResult Function( RsServerEvent_DirectoryDocumentCancelled value)?  directoryDocumentCancelled,TResult Function( RsServerEvent_DirectoryDocumentWrite value)?  directoryDocumentWrite,TResult Function( RsServerEvent_DirectoryDocumentWriteCancelled value)?  directoryDocumentWriteCancelled,TResult Function( RsServerEvent_DirectoryDocumentWriteDraining value)?  directoryDocumentWriteDraining,TResult Function( RsServerEvent_DirectoryUploadApproval value)?  directoryUploadApproval,TResult Function( RsServerEvent_DirectoryUploadApprovalAborted value)?  directoryUploadApprovalAborted,TResult Function( RsServerEvent_WorkspaceManagement value)?  workspaceManagement,TResult Function( RsServerEvent_Register value)?  register,TResult Function( RsServerEvent_PrepareUpload value)?  prepareUpload,TResult Function( RsServerEvent_FileUpload value)?  fileUpload,TResult Function( RsServerEvent_FileVerification value)?  fileVerification,TResult Function( RsServerEvent_ReceiveCacheIdentity value)?  receiveCacheIdentity,TResult Function( RsServerEvent_ReceiveCacheRecovered value)?  receiveCacheRecovered,TResult Function( RsServerEvent_PublishUpload value)?  publishUpload,TResult Function( RsServerEvent_UploadCacheReleased value)?  uploadCacheReleased,TResult Function( RsServerEvent_SessionEnd value)?  sessionEnd,TResult Function( RsServerEvent_PrepareUploadAborted value)?  prepareUploadAborted,TResult Function( RsServerEvent_CancelReceived value)?  cancelReceived,TResult Function( RsServerEvent_WebPrepareDownload value)?  webPrepareDownload,TResult Function( RsServerEvent_WebPrepareDownloadAborted value)?  webPrepareDownloadAborted,TResult Function( RsServerEvent_WebFileDownload value)?  webFileDownload,TResult Function( RsServerEvent_Show value)?  show_,TResult Function( RsServerEvent_ListenerFailed value)?  listenerFailed,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope() when receiveSourceEndScope != null:
return receiveSourceEndScope(_that);case RsServerEvent_DirectoryContent() when directoryContent != null:
return directoryContent(_that);case RsServerEvent_WebDownloadActivity() when webDownloadActivity != null:
return webDownloadActivity(_that);case RsServerEvent_DirectoryDocument() when directoryDocument != null:
return directoryDocument(_that);case RsServerEvent_DirectoryDocumentCancelled() when directoryDocumentCancelled != null:
return directoryDocumentCancelled(_that);case RsServerEvent_DirectoryDocumentWrite() when directoryDocumentWrite != null:
return directoryDocumentWrite(_that);case RsServerEvent_DirectoryDocumentWriteCancelled() when directoryDocumentWriteCancelled != null:
return directoryDocumentWriteCancelled(_that);case RsServerEvent_DirectoryDocumentWriteDraining() when directoryDocumentWriteDraining != null:
return directoryDocumentWriteDraining(_that);case RsServerEvent_DirectoryUploadApproval() when directoryUploadApproval != null:
return directoryUploadApproval(_that);case RsServerEvent_DirectoryUploadApprovalAborted() when directoryUploadApprovalAborted != null:
return directoryUploadApprovalAborted(_that);case RsServerEvent_WorkspaceManagement() when workspaceManagement != null:
return workspaceManagement(_that);case RsServerEvent_Register() when register != null:
return register(_that);case RsServerEvent_PrepareUpload() when prepareUpload != null:
return prepareUpload(_that);case RsServerEvent_FileUpload() when fileUpload != null:
return fileUpload(_that);case RsServerEvent_FileVerification() when fileVerification != null:
return fileVerification(_that);case RsServerEvent_ReceiveCacheIdentity() when receiveCacheIdentity != null:
return receiveCacheIdentity(_that);case RsServerEvent_ReceiveCacheRecovered() when receiveCacheRecovered != null:
return receiveCacheRecovered(_that);case RsServerEvent_PublishUpload() when publishUpload != null:
return publishUpload(_that);case RsServerEvent_UploadCacheReleased() when uploadCacheReleased != null:
return uploadCacheReleased(_that);case RsServerEvent_SessionEnd() when sessionEnd != null:
return sessionEnd(_that);case RsServerEvent_PrepareUploadAborted() when prepareUploadAborted != null:
return prepareUploadAborted(_that);case RsServerEvent_CancelReceived() when cancelReceived != null:
return cancelReceived(_that);case RsServerEvent_WebPrepareDownload() when webPrepareDownload != null:
return webPrepareDownload(_that);case RsServerEvent_WebPrepareDownloadAborted() when webPrepareDownloadAborted != null:
return webPrepareDownloadAborted(_that);case RsServerEvent_WebFileDownload() when webFileDownload != null:
return webFileDownload(_that);case RsServerEvent_Show() when show_ != null:
return show_(_that);case RsServerEvent_ListenerFailed() when listenerFailed != null:
return listenerFailed(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RsServerEvent_ReceiveSourceEndScope value)  receiveSourceEndScope,required TResult Function( RsServerEvent_DirectoryContent value)  directoryContent,required TResult Function( RsServerEvent_WebDownloadActivity value)  webDownloadActivity,required TResult Function( RsServerEvent_DirectoryDocument value)  directoryDocument,required TResult Function( RsServerEvent_DirectoryDocumentCancelled value)  directoryDocumentCancelled,required TResult Function( RsServerEvent_DirectoryDocumentWrite value)  directoryDocumentWrite,required TResult Function( RsServerEvent_DirectoryDocumentWriteCancelled value)  directoryDocumentWriteCancelled,required TResult Function( RsServerEvent_DirectoryDocumentWriteDraining value)  directoryDocumentWriteDraining,required TResult Function( RsServerEvent_DirectoryUploadApproval value)  directoryUploadApproval,required TResult Function( RsServerEvent_DirectoryUploadApprovalAborted value)  directoryUploadApprovalAborted,required TResult Function( RsServerEvent_WorkspaceManagement value)  workspaceManagement,required TResult Function( RsServerEvent_Register value)  register,required TResult Function( RsServerEvent_PrepareUpload value)  prepareUpload,required TResult Function( RsServerEvent_FileUpload value)  fileUpload,required TResult Function( RsServerEvent_FileVerification value)  fileVerification,required TResult Function( RsServerEvent_ReceiveCacheIdentity value)  receiveCacheIdentity,required TResult Function( RsServerEvent_ReceiveCacheRecovered value)  receiveCacheRecovered,required TResult Function( RsServerEvent_PublishUpload value)  publishUpload,required TResult Function( RsServerEvent_UploadCacheReleased value)  uploadCacheReleased,required TResult Function( RsServerEvent_SessionEnd value)  sessionEnd,required TResult Function( RsServerEvent_PrepareUploadAborted value)  prepareUploadAborted,required TResult Function( RsServerEvent_CancelReceived value)  cancelReceived,required TResult Function( RsServerEvent_WebPrepareDownload value)  webPrepareDownload,required TResult Function( RsServerEvent_WebPrepareDownloadAborted value)  webPrepareDownloadAborted,required TResult Function( RsServerEvent_WebFileDownload value)  webFileDownload,required TResult Function( RsServerEvent_Show value)  show_,required TResult Function( RsServerEvent_ListenerFailed value)  listenerFailed,}){
final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope():
return receiveSourceEndScope(_that);case RsServerEvent_DirectoryContent():
return directoryContent(_that);case RsServerEvent_WebDownloadActivity():
return webDownloadActivity(_that);case RsServerEvent_DirectoryDocument():
return directoryDocument(_that);case RsServerEvent_DirectoryDocumentCancelled():
return directoryDocumentCancelled(_that);case RsServerEvent_DirectoryDocumentWrite():
return directoryDocumentWrite(_that);case RsServerEvent_DirectoryDocumentWriteCancelled():
return directoryDocumentWriteCancelled(_that);case RsServerEvent_DirectoryDocumentWriteDraining():
return directoryDocumentWriteDraining(_that);case RsServerEvent_DirectoryUploadApproval():
return directoryUploadApproval(_that);case RsServerEvent_DirectoryUploadApprovalAborted():
return directoryUploadApprovalAborted(_that);case RsServerEvent_WorkspaceManagement():
return workspaceManagement(_that);case RsServerEvent_Register():
return register(_that);case RsServerEvent_PrepareUpload():
return prepareUpload(_that);case RsServerEvent_FileUpload():
return fileUpload(_that);case RsServerEvent_FileVerification():
return fileVerification(_that);case RsServerEvent_ReceiveCacheIdentity():
return receiveCacheIdentity(_that);case RsServerEvent_ReceiveCacheRecovered():
return receiveCacheRecovered(_that);case RsServerEvent_PublishUpload():
return publishUpload(_that);case RsServerEvent_UploadCacheReleased():
return uploadCacheReleased(_that);case RsServerEvent_SessionEnd():
return sessionEnd(_that);case RsServerEvent_PrepareUploadAborted():
return prepareUploadAborted(_that);case RsServerEvent_CancelReceived():
return cancelReceived(_that);case RsServerEvent_WebPrepareDownload():
return webPrepareDownload(_that);case RsServerEvent_WebPrepareDownloadAborted():
return webPrepareDownloadAborted(_that);case RsServerEvent_WebFileDownload():
return webFileDownload(_that);case RsServerEvent_Show():
return show_(_that);case RsServerEvent_ListenerFailed():
return listenerFailed(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RsServerEvent_ReceiveSourceEndScope value)?  receiveSourceEndScope,TResult? Function( RsServerEvent_DirectoryContent value)?  directoryContent,TResult? Function( RsServerEvent_WebDownloadActivity value)?  webDownloadActivity,TResult? Function( RsServerEvent_DirectoryDocument value)?  directoryDocument,TResult? Function( RsServerEvent_DirectoryDocumentCancelled value)?  directoryDocumentCancelled,TResult? Function( RsServerEvent_DirectoryDocumentWrite value)?  directoryDocumentWrite,TResult? Function( RsServerEvent_DirectoryDocumentWriteCancelled value)?  directoryDocumentWriteCancelled,TResult? Function( RsServerEvent_DirectoryDocumentWriteDraining value)?  directoryDocumentWriteDraining,TResult? Function( RsServerEvent_DirectoryUploadApproval value)?  directoryUploadApproval,TResult? Function( RsServerEvent_DirectoryUploadApprovalAborted value)?  directoryUploadApprovalAborted,TResult? Function( RsServerEvent_WorkspaceManagement value)?  workspaceManagement,TResult? Function( RsServerEvent_Register value)?  register,TResult? Function( RsServerEvent_PrepareUpload value)?  prepareUpload,TResult? Function( RsServerEvent_FileUpload value)?  fileUpload,TResult? Function( RsServerEvent_FileVerification value)?  fileVerification,TResult? Function( RsServerEvent_ReceiveCacheIdentity value)?  receiveCacheIdentity,TResult? Function( RsServerEvent_ReceiveCacheRecovered value)?  receiveCacheRecovered,TResult? Function( RsServerEvent_PublishUpload value)?  publishUpload,TResult? Function( RsServerEvent_UploadCacheReleased value)?  uploadCacheReleased,TResult? Function( RsServerEvent_SessionEnd value)?  sessionEnd,TResult? Function( RsServerEvent_PrepareUploadAborted value)?  prepareUploadAborted,TResult? Function( RsServerEvent_CancelReceived value)?  cancelReceived,TResult? Function( RsServerEvent_WebPrepareDownload value)?  webPrepareDownload,TResult? Function( RsServerEvent_WebPrepareDownloadAborted value)?  webPrepareDownloadAborted,TResult? Function( RsServerEvent_WebFileDownload value)?  webFileDownload,TResult? Function( RsServerEvent_Show value)?  show_,TResult? Function( RsServerEvent_ListenerFailed value)?  listenerFailed,}){
final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope() when receiveSourceEndScope != null:
return receiveSourceEndScope(_that);case RsServerEvent_DirectoryContent() when directoryContent != null:
return directoryContent(_that);case RsServerEvent_WebDownloadActivity() when webDownloadActivity != null:
return webDownloadActivity(_that);case RsServerEvent_DirectoryDocument() when directoryDocument != null:
return directoryDocument(_that);case RsServerEvent_DirectoryDocumentCancelled() when directoryDocumentCancelled != null:
return directoryDocumentCancelled(_that);case RsServerEvent_DirectoryDocumentWrite() when directoryDocumentWrite != null:
return directoryDocumentWrite(_that);case RsServerEvent_DirectoryDocumentWriteCancelled() when directoryDocumentWriteCancelled != null:
return directoryDocumentWriteCancelled(_that);case RsServerEvent_DirectoryDocumentWriteDraining() when directoryDocumentWriteDraining != null:
return directoryDocumentWriteDraining(_that);case RsServerEvent_DirectoryUploadApproval() when directoryUploadApproval != null:
return directoryUploadApproval(_that);case RsServerEvent_DirectoryUploadApprovalAborted() when directoryUploadApprovalAborted != null:
return directoryUploadApprovalAborted(_that);case RsServerEvent_WorkspaceManagement() when workspaceManagement != null:
return workspaceManagement(_that);case RsServerEvent_Register() when register != null:
return register(_that);case RsServerEvent_PrepareUpload() when prepareUpload != null:
return prepareUpload(_that);case RsServerEvent_FileUpload() when fileUpload != null:
return fileUpload(_that);case RsServerEvent_FileVerification() when fileVerification != null:
return fileVerification(_that);case RsServerEvent_ReceiveCacheIdentity() when receiveCacheIdentity != null:
return receiveCacheIdentity(_that);case RsServerEvent_ReceiveCacheRecovered() when receiveCacheRecovered != null:
return receiveCacheRecovered(_that);case RsServerEvent_PublishUpload() when publishUpload != null:
return publishUpload(_that);case RsServerEvent_UploadCacheReleased() when uploadCacheReleased != null:
return uploadCacheReleased(_that);case RsServerEvent_SessionEnd() when sessionEnd != null:
return sessionEnd(_that);case RsServerEvent_PrepareUploadAborted() when prepareUploadAborted != null:
return prepareUploadAborted(_that);case RsServerEvent_CancelReceived() when cancelReceived != null:
return cancelReceived(_that);case RsServerEvent_WebPrepareDownload() when webPrepareDownload != null:
return webPrepareDownload(_that);case RsServerEvent_WebPrepareDownloadAborted() when webPrepareDownloadAborted != null:
return webPrepareDownloadAborted(_that);case RsServerEvent_WebFileDownload() when webFileDownload != null:
return webFileDownload(_that);case RsServerEvent_Show() when show_ != null:
return show_(_that);case RsServerEvent_ListenerFailed() when listenerFailed != null:
return listenerFailed(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String requestId,  String directory)?  receiveSourceEndScope,TResult Function( String requestId,  String request)?  directoryContent,TResult Function( String snapshot)?  webDownloadActivity,TResult Function( String requestId,  String request)?  directoryDocument,TResult Function( String requestId)?  directoryDocumentCancelled,TResult Function( String requestId,  String request)?  directoryDocumentWrite,TResult Function( String requestId)?  directoryDocumentWriteCancelled,TResult Function()?  directoryDocumentWriteDraining,TResult Function( String requestId,  String request)?  directoryUploadApproval,TResult Function( String requestId)?  directoryUploadApprovalAborted,TResult Function( String requestId,  String request)?  workspaceManagement,TResult Function( String ip,  RegisterDtoV2 info)?  register,TResult Function( String sessionId,  String ip,  RegisterDtoV2 info,  String? certFingerprint,  Map<String, FileDto> files)?  prepareUpload,TResult Function( String sessionId,  String fileId,  FileDto file,  bool? durableRecovery,  String? recoveryAttemptId)?  fileUpload,TResult Function( String sessionId,  String fileId,  String attemptId,  BigInt verifiedBytes,  BigInt totalBytes,  bool verifying)?  fileVerification,TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String identityJson)?  receiveCacheIdentity,TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String sourceTransactionId,  BigInt sourceLength,  String sourceSha256)?  receiveCacheRecovered,TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  BigInt size,  String sha256)?  publishUpload,TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  bool published)?  uploadCacheReleased,TResult Function( String sessionId,  SessionEndReasonV2 reason)?  sessionEnd,TResult Function( String sessionId)?  prepareUploadAborted,TResult Function( String ip,  String sessionId)?  cancelReceived,TResult Function( String ip,  String sessionId,  String? userAgent)?  webPrepareDownload,TResult Function( String sessionId)?  webPrepareDownloadAborted,TResult Function( String requestId,  String sessionId,  String fileId,  FileDto file)?  webFileDownload,TResult Function( List<String> args)?  show_,TResult Function( String error)?  listenerFailed,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope() when receiveSourceEndScope != null:
return receiveSourceEndScope(_that.requestId,_that.directory);case RsServerEvent_DirectoryContent() when directoryContent != null:
return directoryContent(_that.requestId,_that.request);case RsServerEvent_WebDownloadActivity() when webDownloadActivity != null:
return webDownloadActivity(_that.snapshot);case RsServerEvent_DirectoryDocument() when directoryDocument != null:
return directoryDocument(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentCancelled() when directoryDocumentCancelled != null:
return directoryDocumentCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWrite() when directoryDocumentWrite != null:
return directoryDocumentWrite(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentWriteCancelled() when directoryDocumentWriteCancelled != null:
return directoryDocumentWriteCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWriteDraining() when directoryDocumentWriteDraining != null:
return directoryDocumentWriteDraining();case RsServerEvent_DirectoryUploadApproval() when directoryUploadApproval != null:
return directoryUploadApproval(_that.requestId,_that.request);case RsServerEvent_DirectoryUploadApprovalAborted() when directoryUploadApprovalAborted != null:
return directoryUploadApprovalAborted(_that.requestId);case RsServerEvent_WorkspaceManagement() when workspaceManagement != null:
return workspaceManagement(_that.requestId,_that.request);case RsServerEvent_Register() when register != null:
return register(_that.ip,_that.info);case RsServerEvent_PrepareUpload() when prepareUpload != null:
return prepareUpload(_that.sessionId,_that.ip,_that.info,_that.certFingerprint,_that.files);case RsServerEvent_FileUpload() when fileUpload != null:
return fileUpload(_that.sessionId,_that.fileId,_that.file,_that.durableRecovery,_that.recoveryAttemptId);case RsServerEvent_FileVerification() when fileVerification != null:
return fileVerification(_that.sessionId,_that.fileId,_that.attemptId,_that.verifiedBytes,_that.totalBytes,_that.verifying);case RsServerEvent_ReceiveCacheIdentity() when receiveCacheIdentity != null:
return receiveCacheIdentity(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.identityJson);case RsServerEvent_ReceiveCacheRecovered() when receiveCacheRecovered != null:
return receiveCacheRecovered(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.sourceTransactionId,_that.sourceLength,_that.sourceSha256);case RsServerEvent_PublishUpload() when publishUpload != null:
return publishUpload(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.size,_that.sha256);case RsServerEvent_UploadCacheReleased() when uploadCacheReleased != null:
return uploadCacheReleased(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.published);case RsServerEvent_SessionEnd() when sessionEnd != null:
return sessionEnd(_that.sessionId,_that.reason);case RsServerEvent_PrepareUploadAborted() when prepareUploadAborted != null:
return prepareUploadAborted(_that.sessionId);case RsServerEvent_CancelReceived() when cancelReceived != null:
return cancelReceived(_that.ip,_that.sessionId);case RsServerEvent_WebPrepareDownload() when webPrepareDownload != null:
return webPrepareDownload(_that.ip,_that.sessionId,_that.userAgent);case RsServerEvent_WebPrepareDownloadAborted() when webPrepareDownloadAborted != null:
return webPrepareDownloadAborted(_that.sessionId);case RsServerEvent_WebFileDownload() when webFileDownload != null:
return webFileDownload(_that.requestId,_that.sessionId,_that.fileId,_that.file);case RsServerEvent_Show() when show_ != null:
return show_(_that.args);case RsServerEvent_ListenerFailed() when listenerFailed != null:
return listenerFailed(_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String requestId,  String directory)  receiveSourceEndScope,required TResult Function( String requestId,  String request)  directoryContent,required TResult Function( String snapshot)  webDownloadActivity,required TResult Function( String requestId,  String request)  directoryDocument,required TResult Function( String requestId)  directoryDocumentCancelled,required TResult Function( String requestId,  String request)  directoryDocumentWrite,required TResult Function( String requestId)  directoryDocumentWriteCancelled,required TResult Function()  directoryDocumentWriteDraining,required TResult Function( String requestId,  String request)  directoryUploadApproval,required TResult Function( String requestId)  directoryUploadApprovalAborted,required TResult Function( String requestId,  String request)  workspaceManagement,required TResult Function( String ip,  RegisterDtoV2 info)  register,required TResult Function( String sessionId,  String ip,  RegisterDtoV2 info,  String? certFingerprint,  Map<String, FileDto> files)  prepareUpload,required TResult Function( String sessionId,  String fileId,  FileDto file,  bool? durableRecovery,  String? recoveryAttemptId)  fileUpload,required TResult Function( String sessionId,  String fileId,  String attemptId,  BigInt verifiedBytes,  BigInt totalBytes,  bool verifying)  fileVerification,required TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String identityJson)  receiveCacheIdentity,required TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String sourceTransactionId,  BigInt sourceLength,  String sourceSha256)  receiveCacheRecovered,required TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  BigInt size,  String sha256)  publishUpload,required TResult Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  bool published)  uploadCacheReleased,required TResult Function( String sessionId,  SessionEndReasonV2 reason)  sessionEnd,required TResult Function( String sessionId)  prepareUploadAborted,required TResult Function( String ip,  String sessionId)  cancelReceived,required TResult Function( String ip,  String sessionId,  String? userAgent)  webPrepareDownload,required TResult Function( String sessionId)  webPrepareDownloadAborted,required TResult Function( String requestId,  String sessionId,  String fileId,  FileDto file)  webFileDownload,required TResult Function( List<String> args)  show_,required TResult Function( String error)  listenerFailed,}) {final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope():
return receiveSourceEndScope(_that.requestId,_that.directory);case RsServerEvent_DirectoryContent():
return directoryContent(_that.requestId,_that.request);case RsServerEvent_WebDownloadActivity():
return webDownloadActivity(_that.snapshot);case RsServerEvent_DirectoryDocument():
return directoryDocument(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentCancelled():
return directoryDocumentCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWrite():
return directoryDocumentWrite(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentWriteCancelled():
return directoryDocumentWriteCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWriteDraining():
return directoryDocumentWriteDraining();case RsServerEvent_DirectoryUploadApproval():
return directoryUploadApproval(_that.requestId,_that.request);case RsServerEvent_DirectoryUploadApprovalAborted():
return directoryUploadApprovalAborted(_that.requestId);case RsServerEvent_WorkspaceManagement():
return workspaceManagement(_that.requestId,_that.request);case RsServerEvent_Register():
return register(_that.ip,_that.info);case RsServerEvent_PrepareUpload():
return prepareUpload(_that.sessionId,_that.ip,_that.info,_that.certFingerprint,_that.files);case RsServerEvent_FileUpload():
return fileUpload(_that.sessionId,_that.fileId,_that.file,_that.durableRecovery,_that.recoveryAttemptId);case RsServerEvent_FileVerification():
return fileVerification(_that.sessionId,_that.fileId,_that.attemptId,_that.verifiedBytes,_that.totalBytes,_that.verifying);case RsServerEvent_ReceiveCacheIdentity():
return receiveCacheIdentity(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.identityJson);case RsServerEvent_ReceiveCacheRecovered():
return receiveCacheRecovered(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.sourceTransactionId,_that.sourceLength,_that.sourceSha256);case RsServerEvent_PublishUpload():
return publishUpload(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.size,_that.sha256);case RsServerEvent_UploadCacheReleased():
return uploadCacheReleased(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.published);case RsServerEvent_SessionEnd():
return sessionEnd(_that.sessionId,_that.reason);case RsServerEvent_PrepareUploadAborted():
return prepareUploadAborted(_that.sessionId);case RsServerEvent_CancelReceived():
return cancelReceived(_that.ip,_that.sessionId);case RsServerEvent_WebPrepareDownload():
return webPrepareDownload(_that.ip,_that.sessionId,_that.userAgent);case RsServerEvent_WebPrepareDownloadAborted():
return webPrepareDownloadAborted(_that.sessionId);case RsServerEvent_WebFileDownload():
return webFileDownload(_that.requestId,_that.sessionId,_that.fileId,_that.file);case RsServerEvent_Show():
return show_(_that.args);case RsServerEvent_ListenerFailed():
return listenerFailed(_that.error);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String requestId,  String directory)?  receiveSourceEndScope,TResult? Function( String requestId,  String request)?  directoryContent,TResult? Function( String snapshot)?  webDownloadActivity,TResult? Function( String requestId,  String request)?  directoryDocument,TResult? Function( String requestId)?  directoryDocumentCancelled,TResult? Function( String requestId,  String request)?  directoryDocumentWrite,TResult? Function( String requestId)?  directoryDocumentWriteCancelled,TResult? Function()?  directoryDocumentWriteDraining,TResult? Function( String requestId,  String request)?  directoryUploadApproval,TResult? Function( String requestId)?  directoryUploadApprovalAborted,TResult? Function( String requestId,  String request)?  workspaceManagement,TResult? Function( String ip,  RegisterDtoV2 info)?  register,TResult? Function( String sessionId,  String ip,  RegisterDtoV2 info,  String? certFingerprint,  Map<String, FileDto> files)?  prepareUpload,TResult? Function( String sessionId,  String fileId,  FileDto file,  bool? durableRecovery,  String? recoveryAttemptId)?  fileUpload,TResult? Function( String sessionId,  String fileId,  String attemptId,  BigInt verifiedBytes,  BigInt totalBytes,  bool verifying)?  fileVerification,TResult? Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String identityJson)?  receiveCacheIdentity,TResult? Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  String sourceTransactionId,  BigInt sourceLength,  String sourceSha256)?  receiveCacheRecovered,TResult? Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  BigInt size,  String sha256)?  publishUpload,TResult? Function( String sessionId,  String fileId,  String attemptId,  String transactionId,  bool published)?  uploadCacheReleased,TResult? Function( String sessionId,  SessionEndReasonV2 reason)?  sessionEnd,TResult? Function( String sessionId)?  prepareUploadAborted,TResult? Function( String ip,  String sessionId)?  cancelReceived,TResult? Function( String ip,  String sessionId,  String? userAgent)?  webPrepareDownload,TResult? Function( String sessionId)?  webPrepareDownloadAborted,TResult? Function( String requestId,  String sessionId,  String fileId,  FileDto file)?  webFileDownload,TResult? Function( List<String> args)?  show_,TResult? Function( String error)?  listenerFailed,}) {final _that = this;
switch (_that) {
case RsServerEvent_ReceiveSourceEndScope() when receiveSourceEndScope != null:
return receiveSourceEndScope(_that.requestId,_that.directory);case RsServerEvent_DirectoryContent() when directoryContent != null:
return directoryContent(_that.requestId,_that.request);case RsServerEvent_WebDownloadActivity() when webDownloadActivity != null:
return webDownloadActivity(_that.snapshot);case RsServerEvent_DirectoryDocument() when directoryDocument != null:
return directoryDocument(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentCancelled() when directoryDocumentCancelled != null:
return directoryDocumentCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWrite() when directoryDocumentWrite != null:
return directoryDocumentWrite(_that.requestId,_that.request);case RsServerEvent_DirectoryDocumentWriteCancelled() when directoryDocumentWriteCancelled != null:
return directoryDocumentWriteCancelled(_that.requestId);case RsServerEvent_DirectoryDocumentWriteDraining() when directoryDocumentWriteDraining != null:
return directoryDocumentWriteDraining();case RsServerEvent_DirectoryUploadApproval() when directoryUploadApproval != null:
return directoryUploadApproval(_that.requestId,_that.request);case RsServerEvent_DirectoryUploadApprovalAborted() when directoryUploadApprovalAborted != null:
return directoryUploadApprovalAborted(_that.requestId);case RsServerEvent_WorkspaceManagement() when workspaceManagement != null:
return workspaceManagement(_that.requestId,_that.request);case RsServerEvent_Register() when register != null:
return register(_that.ip,_that.info);case RsServerEvent_PrepareUpload() when prepareUpload != null:
return prepareUpload(_that.sessionId,_that.ip,_that.info,_that.certFingerprint,_that.files);case RsServerEvent_FileUpload() when fileUpload != null:
return fileUpload(_that.sessionId,_that.fileId,_that.file,_that.durableRecovery,_that.recoveryAttemptId);case RsServerEvent_FileVerification() when fileVerification != null:
return fileVerification(_that.sessionId,_that.fileId,_that.attemptId,_that.verifiedBytes,_that.totalBytes,_that.verifying);case RsServerEvent_ReceiveCacheIdentity() when receiveCacheIdentity != null:
return receiveCacheIdentity(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.identityJson);case RsServerEvent_ReceiveCacheRecovered() when receiveCacheRecovered != null:
return receiveCacheRecovered(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.sourceTransactionId,_that.sourceLength,_that.sourceSha256);case RsServerEvent_PublishUpload() when publishUpload != null:
return publishUpload(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.size,_that.sha256);case RsServerEvent_UploadCacheReleased() when uploadCacheReleased != null:
return uploadCacheReleased(_that.sessionId,_that.fileId,_that.attemptId,_that.transactionId,_that.published);case RsServerEvent_SessionEnd() when sessionEnd != null:
return sessionEnd(_that.sessionId,_that.reason);case RsServerEvent_PrepareUploadAborted() when prepareUploadAborted != null:
return prepareUploadAborted(_that.sessionId);case RsServerEvent_CancelReceived() when cancelReceived != null:
return cancelReceived(_that.ip,_that.sessionId);case RsServerEvent_WebPrepareDownload() when webPrepareDownload != null:
return webPrepareDownload(_that.ip,_that.sessionId,_that.userAgent);case RsServerEvent_WebPrepareDownloadAborted() when webPrepareDownloadAborted != null:
return webPrepareDownloadAborted(_that.sessionId);case RsServerEvent_WebFileDownload() when webFileDownload != null:
return webFileDownload(_that.requestId,_that.sessionId,_that.fileId,_that.file);case RsServerEvent_Show() when show_ != null:
return show_(_that.args);case RsServerEvent_ListenerFailed() when listenerFailed != null:
return listenerFailed(_that.error);case _:
  return null;

}
}

}

/// @nodoc


class RsServerEvent_ReceiveSourceEndScope extends RsServerEvent {
  const RsServerEvent_ReceiveSourceEndScope({required this.requestId, required this.directory}): super._();


 final  String requestId;
 final  String directory;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_ReceiveSourceEndScopeCopyWith<RsServerEvent_ReceiveSourceEndScope> get copyWith => _$RsServerEvent_ReceiveSourceEndScopeCopyWithImpl<RsServerEvent_ReceiveSourceEndScope>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_ReceiveSourceEndScope&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.directory, directory) || other.directory == directory));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,directory);

@override
String toString() {
  return 'RsServerEvent.receiveSourceEndScope(requestId: $requestId, directory: $directory)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_ReceiveSourceEndScopeCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_ReceiveSourceEndScopeCopyWith(RsServerEvent_ReceiveSourceEndScope value, $Res Function(RsServerEvent_ReceiveSourceEndScope) _then) = _$RsServerEvent_ReceiveSourceEndScopeCopyWithImpl;
@useResult
$Res call({
 String requestId, String directory
});




}
/// @nodoc
class _$RsServerEvent_ReceiveSourceEndScopeCopyWithImpl<$Res>
    implements $RsServerEvent_ReceiveSourceEndScopeCopyWith<$Res> {
  _$RsServerEvent_ReceiveSourceEndScopeCopyWithImpl(this._self, this._then);

  final RsServerEvent_ReceiveSourceEndScope _self;
  final $Res Function(RsServerEvent_ReceiveSourceEndScope) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? directory = null,}) {
  return _then(RsServerEvent_ReceiveSourceEndScope(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,directory: null == directory ? _self.directory : directory // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryContent extends RsServerEvent {
  const RsServerEvent_DirectoryContent({required this.requestId, required this.request}): super._();


 final  String requestId;
 final  String request;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryContentCopyWith<RsServerEvent_DirectoryContent> get copyWith => _$RsServerEvent_DirectoryContentCopyWithImpl<RsServerEvent_DirectoryContent>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryContent&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.request, request) || other.request == request));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,request);

@override
String toString() {
  return 'RsServerEvent.directoryContent(requestId: $requestId, request: $request)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryContentCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryContentCopyWith(RsServerEvent_DirectoryContent value, $Res Function(RsServerEvent_DirectoryContent) _then) = _$RsServerEvent_DirectoryContentCopyWithImpl;
@useResult
$Res call({
 String requestId, String request
});




}
/// @nodoc
class _$RsServerEvent_DirectoryContentCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryContentCopyWith<$Res> {
  _$RsServerEvent_DirectoryContentCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryContent _self;
  final $Res Function(RsServerEvent_DirectoryContent) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? request = null,}) {
  return _then(RsServerEvent_DirectoryContent(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,request: null == request ? _self.request : request // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_WebDownloadActivity extends RsServerEvent {
  const RsServerEvent_WebDownloadActivity({required this.snapshot}): super._();


 final  String snapshot;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_WebDownloadActivityCopyWith<RsServerEvent_WebDownloadActivity> get copyWith => _$RsServerEvent_WebDownloadActivityCopyWithImpl<RsServerEvent_WebDownloadActivity>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_WebDownloadActivity&&(identical(other.snapshot, snapshot) || other.snapshot == snapshot));
}


@override
int get hashCode => Object.hash(runtimeType,snapshot);

@override
String toString() {
  return 'RsServerEvent.webDownloadActivity(snapshot: $snapshot)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_WebDownloadActivityCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_WebDownloadActivityCopyWith(RsServerEvent_WebDownloadActivity value, $Res Function(RsServerEvent_WebDownloadActivity) _then) = _$RsServerEvent_WebDownloadActivityCopyWithImpl;
@useResult
$Res call({
 String snapshot
});




}
/// @nodoc
class _$RsServerEvent_WebDownloadActivityCopyWithImpl<$Res>
    implements $RsServerEvent_WebDownloadActivityCopyWith<$Res> {
  _$RsServerEvent_WebDownloadActivityCopyWithImpl(this._self, this._then);

  final RsServerEvent_WebDownloadActivity _self;
  final $Res Function(RsServerEvent_WebDownloadActivity) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? snapshot = null,}) {
  return _then(RsServerEvent_WebDownloadActivity(
snapshot: null == snapshot ? _self.snapshot : snapshot // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryDocument extends RsServerEvent {
  const RsServerEvent_DirectoryDocument({required this.requestId, required this.request}): super._();


 final  String requestId;
 final  String request;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryDocumentCopyWith<RsServerEvent_DirectoryDocument> get copyWith => _$RsServerEvent_DirectoryDocumentCopyWithImpl<RsServerEvent_DirectoryDocument>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryDocument&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.request, request) || other.request == request));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,request);

@override
String toString() {
  return 'RsServerEvent.directoryDocument(requestId: $requestId, request: $request)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryDocumentCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryDocumentCopyWith(RsServerEvent_DirectoryDocument value, $Res Function(RsServerEvent_DirectoryDocument) _then) = _$RsServerEvent_DirectoryDocumentCopyWithImpl;
@useResult
$Res call({
 String requestId, String request
});




}
/// @nodoc
class _$RsServerEvent_DirectoryDocumentCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryDocumentCopyWith<$Res> {
  _$RsServerEvent_DirectoryDocumentCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryDocument _self;
  final $Res Function(RsServerEvent_DirectoryDocument) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? request = null,}) {
  return _then(RsServerEvent_DirectoryDocument(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,request: null == request ? _self.request : request // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryDocumentCancelled extends RsServerEvent {
  const RsServerEvent_DirectoryDocumentCancelled({required this.requestId}): super._();


 final  String requestId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryDocumentCancelledCopyWith<RsServerEvent_DirectoryDocumentCancelled> get copyWith => _$RsServerEvent_DirectoryDocumentCancelledCopyWithImpl<RsServerEvent_DirectoryDocumentCancelled>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryDocumentCancelled&&(identical(other.requestId, requestId) || other.requestId == requestId));
}


@override
int get hashCode => Object.hash(runtimeType,requestId);

@override
String toString() {
  return 'RsServerEvent.directoryDocumentCancelled(requestId: $requestId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryDocumentCancelledCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryDocumentCancelledCopyWith(RsServerEvent_DirectoryDocumentCancelled value, $Res Function(RsServerEvent_DirectoryDocumentCancelled) _then) = _$RsServerEvent_DirectoryDocumentCancelledCopyWithImpl;
@useResult
$Res call({
 String requestId
});




}
/// @nodoc
class _$RsServerEvent_DirectoryDocumentCancelledCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryDocumentCancelledCopyWith<$Res> {
  _$RsServerEvent_DirectoryDocumentCancelledCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryDocumentCancelled _self;
  final $Res Function(RsServerEvent_DirectoryDocumentCancelled) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,}) {
  return _then(RsServerEvent_DirectoryDocumentCancelled(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryDocumentWrite extends RsServerEvent {
  const RsServerEvent_DirectoryDocumentWrite({required this.requestId, required this.request}): super._();


 final  String requestId;
 final  String request;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryDocumentWriteCopyWith<RsServerEvent_DirectoryDocumentWrite> get copyWith => _$RsServerEvent_DirectoryDocumentWriteCopyWithImpl<RsServerEvent_DirectoryDocumentWrite>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryDocumentWrite&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.request, request) || other.request == request));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,request);

@override
String toString() {
  return 'RsServerEvent.directoryDocumentWrite(requestId: $requestId, request: $request)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryDocumentWriteCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryDocumentWriteCopyWith(RsServerEvent_DirectoryDocumentWrite value, $Res Function(RsServerEvent_DirectoryDocumentWrite) _then) = _$RsServerEvent_DirectoryDocumentWriteCopyWithImpl;
@useResult
$Res call({
 String requestId, String request
});




}
/// @nodoc
class _$RsServerEvent_DirectoryDocumentWriteCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryDocumentWriteCopyWith<$Res> {
  _$RsServerEvent_DirectoryDocumentWriteCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryDocumentWrite _self;
  final $Res Function(RsServerEvent_DirectoryDocumentWrite) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? request = null,}) {
  return _then(RsServerEvent_DirectoryDocumentWrite(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,request: null == request ? _self.request : request // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryDocumentWriteCancelled extends RsServerEvent {
  const RsServerEvent_DirectoryDocumentWriteCancelled({required this.requestId}): super._();


 final  String requestId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryDocumentWriteCancelledCopyWith<RsServerEvent_DirectoryDocumentWriteCancelled> get copyWith => _$RsServerEvent_DirectoryDocumentWriteCancelledCopyWithImpl<RsServerEvent_DirectoryDocumentWriteCancelled>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryDocumentWriteCancelled&&(identical(other.requestId, requestId) || other.requestId == requestId));
}


@override
int get hashCode => Object.hash(runtimeType,requestId);

@override
String toString() {
  return 'RsServerEvent.directoryDocumentWriteCancelled(requestId: $requestId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryDocumentWriteCancelledCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryDocumentWriteCancelledCopyWith(RsServerEvent_DirectoryDocumentWriteCancelled value, $Res Function(RsServerEvent_DirectoryDocumentWriteCancelled) _then) = _$RsServerEvent_DirectoryDocumentWriteCancelledCopyWithImpl;
@useResult
$Res call({
 String requestId
});




}
/// @nodoc
class _$RsServerEvent_DirectoryDocumentWriteCancelledCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryDocumentWriteCancelledCopyWith<$Res> {
  _$RsServerEvent_DirectoryDocumentWriteCancelledCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryDocumentWriteCancelled _self;
  final $Res Function(RsServerEvent_DirectoryDocumentWriteCancelled) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,}) {
  return _then(RsServerEvent_DirectoryDocumentWriteCancelled(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryDocumentWriteDraining extends RsServerEvent {
  const RsServerEvent_DirectoryDocumentWriteDraining(): super._();







@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryDocumentWriteDraining);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsServerEvent.directoryDocumentWriteDraining()';
}


}




/// @nodoc


class RsServerEvent_DirectoryUploadApproval extends RsServerEvent {
  const RsServerEvent_DirectoryUploadApproval({required this.requestId, required this.request}): super._();


 final  String requestId;
 final  String request;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryUploadApprovalCopyWith<RsServerEvent_DirectoryUploadApproval> get copyWith => _$RsServerEvent_DirectoryUploadApprovalCopyWithImpl<RsServerEvent_DirectoryUploadApproval>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryUploadApproval&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.request, request) || other.request == request));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,request);

@override
String toString() {
  return 'RsServerEvent.directoryUploadApproval(requestId: $requestId, request: $request)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryUploadApprovalCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryUploadApprovalCopyWith(RsServerEvent_DirectoryUploadApproval value, $Res Function(RsServerEvent_DirectoryUploadApproval) _then) = _$RsServerEvent_DirectoryUploadApprovalCopyWithImpl;
@useResult
$Res call({
 String requestId, String request
});




}
/// @nodoc
class _$RsServerEvent_DirectoryUploadApprovalCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryUploadApprovalCopyWith<$Res> {
  _$RsServerEvent_DirectoryUploadApprovalCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryUploadApproval _self;
  final $Res Function(RsServerEvent_DirectoryUploadApproval) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? request = null,}) {
  return _then(RsServerEvent_DirectoryUploadApproval(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,request: null == request ? _self.request : request // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_DirectoryUploadApprovalAborted extends RsServerEvent {
  const RsServerEvent_DirectoryUploadApprovalAborted({required this.requestId}): super._();


 final  String requestId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_DirectoryUploadApprovalAbortedCopyWith<RsServerEvent_DirectoryUploadApprovalAborted> get copyWith => _$RsServerEvent_DirectoryUploadApprovalAbortedCopyWithImpl<RsServerEvent_DirectoryUploadApprovalAborted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_DirectoryUploadApprovalAborted&&(identical(other.requestId, requestId) || other.requestId == requestId));
}


@override
int get hashCode => Object.hash(runtimeType,requestId);

@override
String toString() {
  return 'RsServerEvent.directoryUploadApprovalAborted(requestId: $requestId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_DirectoryUploadApprovalAbortedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_DirectoryUploadApprovalAbortedCopyWith(RsServerEvent_DirectoryUploadApprovalAborted value, $Res Function(RsServerEvent_DirectoryUploadApprovalAborted) _then) = _$RsServerEvent_DirectoryUploadApprovalAbortedCopyWithImpl;
@useResult
$Res call({
 String requestId
});




}
/// @nodoc
class _$RsServerEvent_DirectoryUploadApprovalAbortedCopyWithImpl<$Res>
    implements $RsServerEvent_DirectoryUploadApprovalAbortedCopyWith<$Res> {
  _$RsServerEvent_DirectoryUploadApprovalAbortedCopyWithImpl(this._self, this._then);

  final RsServerEvent_DirectoryUploadApprovalAborted _self;
  final $Res Function(RsServerEvent_DirectoryUploadApprovalAborted) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,}) {
  return _then(RsServerEvent_DirectoryUploadApprovalAborted(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_WorkspaceManagement extends RsServerEvent {
  const RsServerEvent_WorkspaceManagement({required this.requestId, required this.request}): super._();


 final  String requestId;
 final  String request;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_WorkspaceManagementCopyWith<RsServerEvent_WorkspaceManagement> get copyWith => _$RsServerEvent_WorkspaceManagementCopyWithImpl<RsServerEvent_WorkspaceManagement>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_WorkspaceManagement&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.request, request) || other.request == request));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,request);

@override
String toString() {
  return 'RsServerEvent.workspaceManagement(requestId: $requestId, request: $request)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_WorkspaceManagementCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_WorkspaceManagementCopyWith(RsServerEvent_WorkspaceManagement value, $Res Function(RsServerEvent_WorkspaceManagement) _then) = _$RsServerEvent_WorkspaceManagementCopyWithImpl;
@useResult
$Res call({
 String requestId, String request
});




}
/// @nodoc
class _$RsServerEvent_WorkspaceManagementCopyWithImpl<$Res>
    implements $RsServerEvent_WorkspaceManagementCopyWith<$Res> {
  _$RsServerEvent_WorkspaceManagementCopyWithImpl(this._self, this._then);

  final RsServerEvent_WorkspaceManagement _self;
  final $Res Function(RsServerEvent_WorkspaceManagement) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? request = null,}) {
  return _then(RsServerEvent_WorkspaceManagement(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,request: null == request ? _self.request : request // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_Register extends RsServerEvent {
  const RsServerEvent_Register({required this.ip, required this.info}): super._();


 final  String ip;
 final  RegisterDtoV2 info;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_RegisterCopyWith<RsServerEvent_Register> get copyWith => _$RsServerEvent_RegisterCopyWithImpl<RsServerEvent_Register>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_Register&&(identical(other.ip, ip) || other.ip == ip)&&(identical(other.info, info) || other.info == info));
}


@override
int get hashCode => Object.hash(runtimeType,ip,info);

@override
String toString() {
  return 'RsServerEvent.register(ip: $ip, info: $info)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_RegisterCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_RegisterCopyWith(RsServerEvent_Register value, $Res Function(RsServerEvent_Register) _then) = _$RsServerEvent_RegisterCopyWithImpl;
@useResult
$Res call({
 String ip, RegisterDtoV2 info
});




}
/// @nodoc
class _$RsServerEvent_RegisterCopyWithImpl<$Res>
    implements $RsServerEvent_RegisterCopyWith<$Res> {
  _$RsServerEvent_RegisterCopyWithImpl(this._self, this._then);

  final RsServerEvent_Register _self;
  final $Res Function(RsServerEvent_Register) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ip = null,Object? info = null,}) {
  return _then(RsServerEvent_Register(
ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,info: null == info ? _self.info : info // ignore: cast_nullable_to_non_nullable
as RegisterDtoV2,
  ));
}


}

/// @nodoc


class RsServerEvent_PrepareUpload extends RsServerEvent {
  const RsServerEvent_PrepareUpload({required this.sessionId, required this.ip, required this.info, this.certFingerprint, required final  Map<String, FileDto> files}): _files = files,super._();


/// The session ID the upload session will have when the request is accepted.
 final  String sessionId;
 final  String ip;
 final  RegisterDtoV2 info;
/// The SHA-256 fingerprint (uppercase hex) of the sender's client
/// certificate verified during the mTLS handshake. Unlike
/// `info.fingerprint`, this value cannot be spoofed.
/// `None` when the server runs without TLS.
 final  String? certFingerprint;
 final  Map<String, FileDto> _files;
 Map<String, FileDto> get files {
  if (_files is EqualUnmodifiableMapView) return _files;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_files);
}


/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_PrepareUploadCopyWith<RsServerEvent_PrepareUpload> get copyWith => _$RsServerEvent_PrepareUploadCopyWithImpl<RsServerEvent_PrepareUpload>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_PrepareUpload&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.ip, ip) || other.ip == ip)&&(identical(other.info, info) || other.info == info)&&(identical(other.certFingerprint, certFingerprint) || other.certFingerprint == certFingerprint)&&const DeepCollectionEquality().equals(other._files, _files));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,ip,info,certFingerprint,const DeepCollectionEquality().hash(_files));

@override
String toString() {
  return 'RsServerEvent.prepareUpload(sessionId: $sessionId, ip: $ip, info: $info, certFingerprint: $certFingerprint, files: $files)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_PrepareUploadCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_PrepareUploadCopyWith(RsServerEvent_PrepareUpload value, $Res Function(RsServerEvent_PrepareUpload) _then) = _$RsServerEvent_PrepareUploadCopyWithImpl;
@useResult
$Res call({
 String sessionId, String ip, RegisterDtoV2 info, String? certFingerprint, Map<String, FileDto> files
});




}
/// @nodoc
class _$RsServerEvent_PrepareUploadCopyWithImpl<$Res>
    implements $RsServerEvent_PrepareUploadCopyWith<$Res> {
  _$RsServerEvent_PrepareUploadCopyWithImpl(this._self, this._then);

  final RsServerEvent_PrepareUpload _self;
  final $Res Function(RsServerEvent_PrepareUpload) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? ip = null,Object? info = null,Object? certFingerprint = freezed,Object? files = null,}) {
  return _then(RsServerEvent_PrepareUpload(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,info: null == info ? _self.info : info // ignore: cast_nullable_to_non_nullable
as RegisterDtoV2,certFingerprint: freezed == certFingerprint ? _self.certFingerprint : certFingerprint // ignore: cast_nullable_to_non_nullable
as String?,files: null == files ? _self._files : files // ignore: cast_nullable_to_non_nullable
as Map<String, FileDto>,
  ));
}


}

/// @nodoc


class RsServerEvent_FileUpload extends RsServerEvent {
  const RsServerEvent_FileUpload({required this.sessionId, required this.fileId, required this.file, this.durableRecovery, this.recoveryAttemptId}): super._();


 final  String sessionId;
 final  String fileId;
 final  FileDto file;
/// Internal-only approved durable attempt; missing retains original behavior.
 final  bool? durableRecovery;
 final  String? recoveryAttemptId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_FileUploadCopyWith<RsServerEvent_FileUpload> get copyWith => _$RsServerEvent_FileUploadCopyWithImpl<RsServerEvent_FileUpload>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_FileUpload&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.file, file) || other.file == file)&&(identical(other.durableRecovery, durableRecovery) || other.durableRecovery == durableRecovery)&&(identical(other.recoveryAttemptId, recoveryAttemptId) || other.recoveryAttemptId == recoveryAttemptId));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,file,durableRecovery,recoveryAttemptId);

@override
String toString() {
  return 'RsServerEvent.fileUpload(sessionId: $sessionId, fileId: $fileId, file: $file, durableRecovery: $durableRecovery, recoveryAttemptId: $recoveryAttemptId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_FileUploadCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_FileUploadCopyWith(RsServerEvent_FileUpload value, $Res Function(RsServerEvent_FileUpload) _then) = _$RsServerEvent_FileUploadCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, FileDto file, bool? durableRecovery, String? recoveryAttemptId
});




}
/// @nodoc
class _$RsServerEvent_FileUploadCopyWithImpl<$Res>
    implements $RsServerEvent_FileUploadCopyWith<$Res> {
  _$RsServerEvent_FileUploadCopyWithImpl(this._self, this._then);

  final RsServerEvent_FileUpload _self;
  final $Res Function(RsServerEvent_FileUpload) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? file = null,Object? durableRecovery = freezed,Object? recoveryAttemptId = freezed,}) {
  return _then(RsServerEvent_FileUpload(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,file: null == file ? _self.file : file // ignore: cast_nullable_to_non_nullable
as FileDto,durableRecovery: freezed == durableRecovery ? _self.durableRecovery : durableRecovery // ignore: cast_nullable_to_non_nullable
as bool?,recoveryAttemptId: freezed == recoveryAttemptId ? _self.recoveryAttemptId : recoveryAttemptId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class RsServerEvent_FileVerification extends RsServerEvent {
  const RsServerEvent_FileVerification({required this.sessionId, required this.fileId, required this.attemptId, required this.verifiedBytes, required this.totalBytes, required this.verifying}): super._();


 final  String sessionId;
 final  String fileId;
 final  String attemptId;
 final  BigInt verifiedBytes;
 final  BigInt totalBytes;
 final  bool verifying;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_FileVerificationCopyWith<RsServerEvent_FileVerification> get copyWith => _$RsServerEvent_FileVerificationCopyWithImpl<RsServerEvent_FileVerification>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_FileVerification&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.attemptId, attemptId) || other.attemptId == attemptId)&&(identical(other.verifiedBytes, verifiedBytes) || other.verifiedBytes == verifiedBytes)&&(identical(other.totalBytes, totalBytes) || other.totalBytes == totalBytes)&&(identical(other.verifying, verifying) || other.verifying == verifying));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,attemptId,verifiedBytes,totalBytes,verifying);

@override
String toString() {
  return 'RsServerEvent.fileVerification(sessionId: $sessionId, fileId: $fileId, attemptId: $attemptId, verifiedBytes: $verifiedBytes, totalBytes: $totalBytes, verifying: $verifying)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_FileVerificationCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_FileVerificationCopyWith(RsServerEvent_FileVerification value, $Res Function(RsServerEvent_FileVerification) _then) = _$RsServerEvent_FileVerificationCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, String attemptId, BigInt verifiedBytes, BigInt totalBytes, bool verifying
});




}
/// @nodoc
class _$RsServerEvent_FileVerificationCopyWithImpl<$Res>
    implements $RsServerEvent_FileVerificationCopyWith<$Res> {
  _$RsServerEvent_FileVerificationCopyWithImpl(this._self, this._then);

  final RsServerEvent_FileVerification _self;
  final $Res Function(RsServerEvent_FileVerification) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? attemptId = null,Object? verifiedBytes = null,Object? totalBytes = null,Object? verifying = null,}) {
  return _then(RsServerEvent_FileVerification(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,attemptId: null == attemptId ? _self.attemptId : attemptId // ignore: cast_nullable_to_non_nullable
as String,verifiedBytes: null == verifiedBytes ? _self.verifiedBytes : verifiedBytes // ignore: cast_nullable_to_non_nullable
as BigInt,totalBytes: null == totalBytes ? _self.totalBytes : totalBytes // ignore: cast_nullable_to_non_nullable
as BigInt,verifying: null == verifying ? _self.verifying : verifying // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RsServerEvent_ReceiveCacheIdentity extends RsServerEvent {
  const RsServerEvent_ReceiveCacheIdentity({required this.sessionId, required this.fileId, required this.attemptId, required this.transactionId, required this.identityJson}): super._();


 final  String sessionId;
 final  String fileId;
 final  String attemptId;
 final  String transactionId;
 final  String identityJson;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_ReceiveCacheIdentityCopyWith<RsServerEvent_ReceiveCacheIdentity> get copyWith => _$RsServerEvent_ReceiveCacheIdentityCopyWithImpl<RsServerEvent_ReceiveCacheIdentity>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_ReceiveCacheIdentity&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.attemptId, attemptId) || other.attemptId == attemptId)&&(identical(other.transactionId, transactionId) || other.transactionId == transactionId)&&(identical(other.identityJson, identityJson) || other.identityJson == identityJson));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,attemptId,transactionId,identityJson);

@override
String toString() {
  return 'RsServerEvent.receiveCacheIdentity(sessionId: $sessionId, fileId: $fileId, attemptId: $attemptId, transactionId: $transactionId, identityJson: $identityJson)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_ReceiveCacheIdentityCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_ReceiveCacheIdentityCopyWith(RsServerEvent_ReceiveCacheIdentity value, $Res Function(RsServerEvent_ReceiveCacheIdentity) _then) = _$RsServerEvent_ReceiveCacheIdentityCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, String attemptId, String transactionId, String identityJson
});




}
/// @nodoc
class _$RsServerEvent_ReceiveCacheIdentityCopyWithImpl<$Res>
    implements $RsServerEvent_ReceiveCacheIdentityCopyWith<$Res> {
  _$RsServerEvent_ReceiveCacheIdentityCopyWithImpl(this._self, this._then);

  final RsServerEvent_ReceiveCacheIdentity _self;
  final $Res Function(RsServerEvent_ReceiveCacheIdentity) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? attemptId = null,Object? transactionId = null,Object? identityJson = null,}) {
  return _then(RsServerEvent_ReceiveCacheIdentity(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,attemptId: null == attemptId ? _self.attemptId : attemptId // ignore: cast_nullable_to_non_nullable
as String,transactionId: null == transactionId ? _self.transactionId : transactionId // ignore: cast_nullable_to_non_nullable
as String,identityJson: null == identityJson ? _self.identityJson : identityJson // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_ReceiveCacheRecovered extends RsServerEvent {
  const RsServerEvent_ReceiveCacheRecovered({required this.sessionId, required this.fileId, required this.attemptId, required this.transactionId, required this.sourceTransactionId, required this.sourceLength, required this.sourceSha256}): super._();


 final  String sessionId;
 final  String fileId;
 final  String attemptId;
 final  String transactionId;
 final  String sourceTransactionId;
 final  BigInt sourceLength;
 final  String sourceSha256;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_ReceiveCacheRecoveredCopyWith<RsServerEvent_ReceiveCacheRecovered> get copyWith => _$RsServerEvent_ReceiveCacheRecoveredCopyWithImpl<RsServerEvent_ReceiveCacheRecovered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_ReceiveCacheRecovered&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.attemptId, attemptId) || other.attemptId == attemptId)&&(identical(other.transactionId, transactionId) || other.transactionId == transactionId)&&(identical(other.sourceTransactionId, sourceTransactionId) || other.sourceTransactionId == sourceTransactionId)&&(identical(other.sourceLength, sourceLength) || other.sourceLength == sourceLength)&&(identical(other.sourceSha256, sourceSha256) || other.sourceSha256 == sourceSha256));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,attemptId,transactionId,sourceTransactionId,sourceLength,sourceSha256);

@override
String toString() {
  return 'RsServerEvent.receiveCacheRecovered(sessionId: $sessionId, fileId: $fileId, attemptId: $attemptId, transactionId: $transactionId, sourceTransactionId: $sourceTransactionId, sourceLength: $sourceLength, sourceSha256: $sourceSha256)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_ReceiveCacheRecoveredCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_ReceiveCacheRecoveredCopyWith(RsServerEvent_ReceiveCacheRecovered value, $Res Function(RsServerEvent_ReceiveCacheRecovered) _then) = _$RsServerEvent_ReceiveCacheRecoveredCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, String attemptId, String transactionId, String sourceTransactionId, BigInt sourceLength, String sourceSha256
});




}
/// @nodoc
class _$RsServerEvent_ReceiveCacheRecoveredCopyWithImpl<$Res>
    implements $RsServerEvent_ReceiveCacheRecoveredCopyWith<$Res> {
  _$RsServerEvent_ReceiveCacheRecoveredCopyWithImpl(this._self, this._then);

  final RsServerEvent_ReceiveCacheRecovered _self;
  final $Res Function(RsServerEvent_ReceiveCacheRecovered) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? attemptId = null,Object? transactionId = null,Object? sourceTransactionId = null,Object? sourceLength = null,Object? sourceSha256 = null,}) {
  return _then(RsServerEvent_ReceiveCacheRecovered(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,attemptId: null == attemptId ? _self.attemptId : attemptId // ignore: cast_nullable_to_non_nullable
as String,transactionId: null == transactionId ? _self.transactionId : transactionId // ignore: cast_nullable_to_non_nullable
as String,sourceTransactionId: null == sourceTransactionId ? _self.sourceTransactionId : sourceTransactionId // ignore: cast_nullable_to_non_nullable
as String,sourceLength: null == sourceLength ? _self.sourceLength : sourceLength // ignore: cast_nullable_to_non_nullable
as BigInt,sourceSha256: null == sourceSha256 ? _self.sourceSha256 : sourceSha256 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_PublishUpload extends RsServerEvent {
  const RsServerEvent_PublishUpload({required this.sessionId, required this.fileId, required this.attemptId, required this.transactionId, required this.size, required this.sha256}): super._();


 final  String sessionId;
 final  String fileId;
 final  String attemptId;
 final  String transactionId;
 final  BigInt size;
 final  String sha256;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_PublishUploadCopyWith<RsServerEvent_PublishUpload> get copyWith => _$RsServerEvent_PublishUploadCopyWithImpl<RsServerEvent_PublishUpload>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_PublishUpload&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.attemptId, attemptId) || other.attemptId == attemptId)&&(identical(other.transactionId, transactionId) || other.transactionId == transactionId)&&(identical(other.size, size) || other.size == size)&&(identical(other.sha256, sha256) || other.sha256 == sha256));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,attemptId,transactionId,size,sha256);

@override
String toString() {
  return 'RsServerEvent.publishUpload(sessionId: $sessionId, fileId: $fileId, attemptId: $attemptId, transactionId: $transactionId, size: $size, sha256: $sha256)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_PublishUploadCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_PublishUploadCopyWith(RsServerEvent_PublishUpload value, $Res Function(RsServerEvent_PublishUpload) _then) = _$RsServerEvent_PublishUploadCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, String attemptId, String transactionId, BigInt size, String sha256
});




}
/// @nodoc
class _$RsServerEvent_PublishUploadCopyWithImpl<$Res>
    implements $RsServerEvent_PublishUploadCopyWith<$Res> {
  _$RsServerEvent_PublishUploadCopyWithImpl(this._self, this._then);

  final RsServerEvent_PublishUpload _self;
  final $Res Function(RsServerEvent_PublishUpload) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? attemptId = null,Object? transactionId = null,Object? size = null,Object? sha256 = null,}) {
  return _then(RsServerEvent_PublishUpload(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,attemptId: null == attemptId ? _self.attemptId : attemptId // ignore: cast_nullable_to_non_nullable
as String,transactionId: null == transactionId ? _self.transactionId : transactionId // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as BigInt,sha256: null == sha256 ? _self.sha256 : sha256 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_UploadCacheReleased extends RsServerEvent {
  const RsServerEvent_UploadCacheReleased({required this.sessionId, required this.fileId, required this.attemptId, required this.transactionId, required this.published}): super._();


 final  String sessionId;
 final  String fileId;
 final  String attemptId;
 final  String transactionId;
 final  bool published;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_UploadCacheReleasedCopyWith<RsServerEvent_UploadCacheReleased> get copyWith => _$RsServerEvent_UploadCacheReleasedCopyWithImpl<RsServerEvent_UploadCacheReleased>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_UploadCacheReleased&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.attemptId, attemptId) || other.attemptId == attemptId)&&(identical(other.transactionId, transactionId) || other.transactionId == transactionId)&&(identical(other.published, published) || other.published == published));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,fileId,attemptId,transactionId,published);

@override
String toString() {
  return 'RsServerEvent.uploadCacheReleased(sessionId: $sessionId, fileId: $fileId, attemptId: $attemptId, transactionId: $transactionId, published: $published)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_UploadCacheReleasedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_UploadCacheReleasedCopyWith(RsServerEvent_UploadCacheReleased value, $Res Function(RsServerEvent_UploadCacheReleased) _then) = _$RsServerEvent_UploadCacheReleasedCopyWithImpl;
@useResult
$Res call({
 String sessionId, String fileId, String attemptId, String transactionId, bool published
});




}
/// @nodoc
class _$RsServerEvent_UploadCacheReleasedCopyWithImpl<$Res>
    implements $RsServerEvent_UploadCacheReleasedCopyWith<$Res> {
  _$RsServerEvent_UploadCacheReleasedCopyWithImpl(this._self, this._then);

  final RsServerEvent_UploadCacheReleased _self;
  final $Res Function(RsServerEvent_UploadCacheReleased) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? fileId = null,Object? attemptId = null,Object? transactionId = null,Object? published = null,}) {
  return _then(RsServerEvent_UploadCacheReleased(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,attemptId: null == attemptId ? _self.attemptId : attemptId // ignore: cast_nullable_to_non_nullable
as String,transactionId: null == transactionId ? _self.transactionId : transactionId // ignore: cast_nullable_to_non_nullable
as String,published: null == published ? _self.published : published // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RsServerEvent_SessionEnd extends RsServerEvent {
  const RsServerEvent_SessionEnd({required this.sessionId, required this.reason}): super._();


 final  String sessionId;
 final  SessionEndReasonV2 reason;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_SessionEndCopyWith<RsServerEvent_SessionEnd> get copyWith => _$RsServerEvent_SessionEndCopyWithImpl<RsServerEvent_SessionEnd>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_SessionEnd&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,reason);

@override
String toString() {
  return 'RsServerEvent.sessionEnd(sessionId: $sessionId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_SessionEndCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_SessionEndCopyWith(RsServerEvent_SessionEnd value, $Res Function(RsServerEvent_SessionEnd) _then) = _$RsServerEvent_SessionEndCopyWithImpl;
@useResult
$Res call({
 String sessionId, SessionEndReasonV2 reason
});




}
/// @nodoc
class _$RsServerEvent_SessionEndCopyWithImpl<$Res>
    implements $RsServerEvent_SessionEndCopyWith<$Res> {
  _$RsServerEvent_SessionEndCopyWithImpl(this._self, this._then);

  final RsServerEvent_SessionEnd _self;
  final $Res Function(RsServerEvent_SessionEnd) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? reason = null,}) {
  return _then(RsServerEvent_SessionEnd(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as SessionEndReasonV2,
  ));
}


}

/// @nodoc


class RsServerEvent_PrepareUploadAborted extends RsServerEvent {
  const RsServerEvent_PrepareUploadAborted({required this.sessionId}): super._();


 final  String sessionId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_PrepareUploadAbortedCopyWith<RsServerEvent_PrepareUploadAborted> get copyWith => _$RsServerEvent_PrepareUploadAbortedCopyWithImpl<RsServerEvent_PrepareUploadAborted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_PrepareUploadAborted&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId);

@override
String toString() {
  return 'RsServerEvent.prepareUploadAborted(sessionId: $sessionId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_PrepareUploadAbortedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_PrepareUploadAbortedCopyWith(RsServerEvent_PrepareUploadAborted value, $Res Function(RsServerEvent_PrepareUploadAborted) _then) = _$RsServerEvent_PrepareUploadAbortedCopyWithImpl;
@useResult
$Res call({
 String sessionId
});




}
/// @nodoc
class _$RsServerEvent_PrepareUploadAbortedCopyWithImpl<$Res>
    implements $RsServerEvent_PrepareUploadAbortedCopyWith<$Res> {
  _$RsServerEvent_PrepareUploadAbortedCopyWithImpl(this._self, this._then);

  final RsServerEvent_PrepareUploadAborted _self;
  final $Res Function(RsServerEvent_PrepareUploadAborted) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,}) {
  return _then(RsServerEvent_PrepareUploadAborted(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_CancelReceived extends RsServerEvent {
  const RsServerEvent_CancelReceived({required this.ip, required this.sessionId}): super._();


 final  String ip;
 final  String sessionId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_CancelReceivedCopyWith<RsServerEvent_CancelReceived> get copyWith => _$RsServerEvent_CancelReceivedCopyWithImpl<RsServerEvent_CancelReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_CancelReceived&&(identical(other.ip, ip) || other.ip == ip)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId));
}


@override
int get hashCode => Object.hash(runtimeType,ip,sessionId);

@override
String toString() {
  return 'RsServerEvent.cancelReceived(ip: $ip, sessionId: $sessionId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_CancelReceivedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_CancelReceivedCopyWith(RsServerEvent_CancelReceived value, $Res Function(RsServerEvent_CancelReceived) _then) = _$RsServerEvent_CancelReceivedCopyWithImpl;
@useResult
$Res call({
 String ip, String sessionId
});




}
/// @nodoc
class _$RsServerEvent_CancelReceivedCopyWithImpl<$Res>
    implements $RsServerEvent_CancelReceivedCopyWith<$Res> {
  _$RsServerEvent_CancelReceivedCopyWithImpl(this._self, this._then);

  final RsServerEvent_CancelReceived _self;
  final $Res Function(RsServerEvent_CancelReceived) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ip = null,Object? sessionId = null,}) {
  return _then(RsServerEvent_CancelReceived(
ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_WebPrepareDownload extends RsServerEvent {
  const RsServerEvent_WebPrepareDownload({required this.ip, required this.sessionId, this.userAgent}): super._();


 final  String ip;
 final  String sessionId;
 final  String? userAgent;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_WebPrepareDownloadCopyWith<RsServerEvent_WebPrepareDownload> get copyWith => _$RsServerEvent_WebPrepareDownloadCopyWithImpl<RsServerEvent_WebPrepareDownload>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_WebPrepareDownload&&(identical(other.ip, ip) || other.ip == ip)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.userAgent, userAgent) || other.userAgent == userAgent));
}


@override
int get hashCode => Object.hash(runtimeType,ip,sessionId,userAgent);

@override
String toString() {
  return 'RsServerEvent.webPrepareDownload(ip: $ip, sessionId: $sessionId, userAgent: $userAgent)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_WebPrepareDownloadCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_WebPrepareDownloadCopyWith(RsServerEvent_WebPrepareDownload value, $Res Function(RsServerEvent_WebPrepareDownload) _then) = _$RsServerEvent_WebPrepareDownloadCopyWithImpl;
@useResult
$Res call({
 String ip, String sessionId, String? userAgent
});




}
/// @nodoc
class _$RsServerEvent_WebPrepareDownloadCopyWithImpl<$Res>
    implements $RsServerEvent_WebPrepareDownloadCopyWith<$Res> {
  _$RsServerEvent_WebPrepareDownloadCopyWithImpl(this._self, this._then);

  final RsServerEvent_WebPrepareDownload _self;
  final $Res Function(RsServerEvent_WebPrepareDownload) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ip = null,Object? sessionId = null,Object? userAgent = freezed,}) {
  return _then(RsServerEvent_WebPrepareDownload(
ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,userAgent: freezed == userAgent ? _self.userAgent : userAgent // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class RsServerEvent_WebPrepareDownloadAborted extends RsServerEvent {
  const RsServerEvent_WebPrepareDownloadAborted({required this.sessionId}): super._();


 final  String sessionId;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_WebPrepareDownloadAbortedCopyWith<RsServerEvent_WebPrepareDownloadAborted> get copyWith => _$RsServerEvent_WebPrepareDownloadAbortedCopyWithImpl<RsServerEvent_WebPrepareDownloadAborted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_WebPrepareDownloadAborted&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId);

@override
String toString() {
  return 'RsServerEvent.webPrepareDownloadAborted(sessionId: $sessionId)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_WebPrepareDownloadAbortedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_WebPrepareDownloadAbortedCopyWith(RsServerEvent_WebPrepareDownloadAborted value, $Res Function(RsServerEvent_WebPrepareDownloadAborted) _then) = _$RsServerEvent_WebPrepareDownloadAbortedCopyWithImpl;
@useResult
$Res call({
 String sessionId
});




}
/// @nodoc
class _$RsServerEvent_WebPrepareDownloadAbortedCopyWithImpl<$Res>
    implements $RsServerEvent_WebPrepareDownloadAbortedCopyWith<$Res> {
  _$RsServerEvent_WebPrepareDownloadAbortedCopyWithImpl(this._self, this._then);

  final RsServerEvent_WebPrepareDownloadAborted _self;
  final $Res Function(RsServerEvent_WebPrepareDownloadAborted) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,}) {
  return _then(RsServerEvent_WebPrepareDownloadAborted(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsServerEvent_WebFileDownload extends RsServerEvent {
  const RsServerEvent_WebFileDownload({required this.requestId, required this.sessionId, required this.fileId, required this.file}): super._();


 final  String requestId;
 final  String sessionId;
 final  String fileId;
 final  FileDto file;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_WebFileDownloadCopyWith<RsServerEvent_WebFileDownload> get copyWith => _$RsServerEvent_WebFileDownloadCopyWithImpl<RsServerEvent_WebFileDownload>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_WebFileDownload&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.fileId, fileId) || other.fileId == fileId)&&(identical(other.file, file) || other.file == file));
}


@override
int get hashCode => Object.hash(runtimeType,requestId,sessionId,fileId,file);

@override
String toString() {
  return 'RsServerEvent.webFileDownload(requestId: $requestId, sessionId: $sessionId, fileId: $fileId, file: $file)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_WebFileDownloadCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_WebFileDownloadCopyWith(RsServerEvent_WebFileDownload value, $Res Function(RsServerEvent_WebFileDownload) _then) = _$RsServerEvent_WebFileDownloadCopyWithImpl;
@useResult
$Res call({
 String requestId, String sessionId, String fileId, FileDto file
});




}
/// @nodoc
class _$RsServerEvent_WebFileDownloadCopyWithImpl<$Res>
    implements $RsServerEvent_WebFileDownloadCopyWith<$Res> {
  _$RsServerEvent_WebFileDownloadCopyWithImpl(this._self, this._then);

  final RsServerEvent_WebFileDownload _self;
  final $Res Function(RsServerEvent_WebFileDownload) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? requestId = null,Object? sessionId = null,Object? fileId = null,Object? file = null,}) {
  return _then(RsServerEvent_WebFileDownload(
requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,fileId: null == fileId ? _self.fileId : fileId // ignore: cast_nullable_to_non_nullable
as String,file: null == file ? _self.file : file // ignore: cast_nullable_to_non_nullable
as FileDto,
  ));
}


}

/// @nodoc


class RsServerEvent_Show extends RsServerEvent {
  const RsServerEvent_Show({required final  List<String> args}): _args = args,super._();


/// Command-line arguments forwarded by the other application instance.
 final  List<String> _args;
/// Command-line arguments forwarded by the other application instance.
 List<String> get args {
  if (_args is EqualUnmodifiableListView) return _args;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_args);
}


/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_ShowCopyWith<RsServerEvent_Show> get copyWith => _$RsServerEvent_ShowCopyWithImpl<RsServerEvent_Show>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_Show&&const DeepCollectionEquality().equals(other._args, _args));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_args));

@override
String toString() {
  return 'RsServerEvent.show_(args: $args)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_ShowCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_ShowCopyWith(RsServerEvent_Show value, $Res Function(RsServerEvent_Show) _then) = _$RsServerEvent_ShowCopyWithImpl;
@useResult
$Res call({
 List<String> args
});




}
/// @nodoc
class _$RsServerEvent_ShowCopyWithImpl<$Res>
    implements $RsServerEvent_ShowCopyWith<$Res> {
  _$RsServerEvent_ShowCopyWithImpl(this._self, this._then);

  final RsServerEvent_Show _self;
  final $Res Function(RsServerEvent_Show) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? args = null,}) {
  return _then(RsServerEvent_Show(
args: null == args ? _self._args : args // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

/// @nodoc


class RsServerEvent_ListenerFailed extends RsServerEvent {
  const RsServerEvent_ListenerFailed({required this.error}): super._();


/// Description of the failure.
 final  String error;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsServerEvent_ListenerFailedCopyWith<RsServerEvent_ListenerFailed> get copyWith => _$RsServerEvent_ListenerFailedCopyWithImpl<RsServerEvent_ListenerFailed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsServerEvent_ListenerFailed&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode => Object.hash(runtimeType,error);

@override
String toString() {
  return 'RsServerEvent.listenerFailed(error: $error)';
}


}

/// @nodoc
abstract mixin class $RsServerEvent_ListenerFailedCopyWith<$Res> implements $RsServerEventCopyWith<$Res> {
  factory $RsServerEvent_ListenerFailedCopyWith(RsServerEvent_ListenerFailed value, $Res Function(RsServerEvent_ListenerFailed) _then) = _$RsServerEvent_ListenerFailedCopyWithImpl;
@useResult
$Res call({
 String error
});




}
/// @nodoc
class _$RsServerEvent_ListenerFailedCopyWithImpl<$Res>
    implements $RsServerEvent_ListenerFailedCopyWith<$Res> {
  _$RsServerEvent_ListenerFailedCopyWithImpl(this._self, this._then);

  final RsServerEvent_ListenerFailed _self;
  final $Res Function(RsServerEvent_ListenerFailed) _then;

/// Create a copy of RsServerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? error = null,}) {
  return _then(RsServerEvent_ListenerFailed(
error: null == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$WebMode {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebMode);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'WebMode()';
}


}

/// @nodoc
class $WebModeCopyWith<$Res>  {
$WebModeCopyWith(WebMode _, $Res Function(WebMode) __);
}


/// Adds pattern-matching-related methods to [WebMode].
extension WebModePatterns on WebMode {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( WebMode_Disabled value)?  disabled,TResult Function( WebMode_Download value)?  download,TResult Function( WebMode_Upload value)?  upload,TResult Function( WebMode_Duplex value)?  duplex,required TResult orElse(),}){
final _that = this;
switch (_that) {
case WebMode_Disabled() when disabled != null:
return disabled(_that);case WebMode_Download() when download != null:
return download(_that);case WebMode_Upload() when upload != null:
return upload(_that);case WebMode_Duplex() when duplex != null:
return duplex(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( WebMode_Disabled value)  disabled,required TResult Function( WebMode_Download value)  download,required TResult Function( WebMode_Upload value)  upload,required TResult Function( WebMode_Duplex value)  duplex,}){
final _that = this;
switch (_that) {
case WebMode_Disabled():
return disabled(_that);case WebMode_Download():
return download(_that);case WebMode_Upload():
return upload(_that);case WebMode_Duplex():
return duplex(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( WebMode_Disabled value)?  disabled,TResult? Function( WebMode_Download value)?  download,TResult? Function( WebMode_Upload value)?  upload,TResult? Function( WebMode_Duplex value)?  duplex,}){
final _that = this;
switch (_that) {
case WebMode_Disabled() when disabled != null:
return disabled(_that);case WebMode_Download() when download != null:
return download(_that);case WebMode_Upload() when upload != null:
return upload(_that);case WebMode_Duplex() when duplex != null:
return duplex(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  disabled,TResult Function( Map<String, FileDto> files,  String? pin)?  download,TResult Function()?  upload,TResult Function( Map<String, FileDto> files,  String? pin,  bool allowUpload)?  duplex,required TResult orElse(),}) {final _that = this;
switch (_that) {
case WebMode_Disabled() when disabled != null:
return disabled();case WebMode_Download() when download != null:
return download(_that.files,_that.pin);case WebMode_Upload() when upload != null:
return upload();case WebMode_Duplex() when duplex != null:
return duplex(_that.files,_that.pin,_that.allowUpload);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  disabled,required TResult Function( Map<String, FileDto> files,  String? pin)  download,required TResult Function()  upload,required TResult Function( Map<String, FileDto> files,  String? pin,  bool allowUpload)  duplex,}) {final _that = this;
switch (_that) {
case WebMode_Disabled():
return disabled();case WebMode_Download():
return download(_that.files,_that.pin);case WebMode_Upload():
return upload();case WebMode_Duplex():
return duplex(_that.files,_that.pin,_that.allowUpload);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  disabled,TResult? Function( Map<String, FileDto> files,  String? pin)?  download,TResult? Function()?  upload,TResult? Function( Map<String, FileDto> files,  String? pin,  bool allowUpload)?  duplex,}) {final _that = this;
switch (_that) {
case WebMode_Disabled() when disabled != null:
return disabled();case WebMode_Download() when download != null:
return download(_that.files,_that.pin);case WebMode_Upload() when upload != null:
return upload();case WebMode_Duplex() when duplex != null:
return duplex(_that.files,_that.pin,_that.allowUpload);case _:
  return null;

}
}

}

/// @nodoc


class WebMode_Disabled extends WebMode {
  const WebMode_Disabled(): super._();







@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebMode_Disabled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'WebMode.disabled()';
}


}




/// @nodoc


class WebMode_Download extends WebMode {
  const WebMode_Download({required final  Map<String, FileDto> files, this.pin}): _files = files,super._();


/// The metadata of the files offered for download, mapped by file ID.
/// The content is requested per download via [RsServerEvent::WebFileDownload].
 final  Map<String, FileDto> _files;
/// The metadata of the files offered for download, mapped by file ID.
/// The content is requested per download via [RsServerEvent::WebFileDownload].
 Map<String, FileDto> get files {
  if (_files is EqualUnmodifiableMapView) return _files;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_files);
}

/// Optional PIN that web clients must provide via the `pin` query parameter.
 final  String? pin;

/// Create a copy of WebMode
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WebMode_DownloadCopyWith<WebMode_Download> get copyWith => _$WebMode_DownloadCopyWithImpl<WebMode_Download>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebMode_Download&&const DeepCollectionEquality().equals(other._files, _files)&&(identical(other.pin, pin) || other.pin == pin));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_files),pin);

@override
String toString() {
  return 'WebMode.download(files: $files, pin: $pin)';
}


}

/// @nodoc
abstract mixin class $WebMode_DownloadCopyWith<$Res> implements $WebModeCopyWith<$Res> {
  factory $WebMode_DownloadCopyWith(WebMode_Download value, $Res Function(WebMode_Download) _then) = _$WebMode_DownloadCopyWithImpl;
@useResult
$Res call({
 Map<String, FileDto> files, String? pin
});




}
/// @nodoc
class _$WebMode_DownloadCopyWithImpl<$Res>
    implements $WebMode_DownloadCopyWith<$Res> {
  _$WebMode_DownloadCopyWithImpl(this._self, this._then);

  final WebMode_Download _self;
  final $Res Function(WebMode_Download) _then;

/// Create a copy of WebMode
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? files = null,Object? pin = freezed,}) {
  return _then(WebMode_Download(
files: null == files ? _self._files : files // ignore: cast_nullable_to_non_nullable
as Map<String, FileDto>,pin: freezed == pin ? _self.pin : pin // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class WebMode_Upload extends WebMode {
  const WebMode_Upload(): super._();







@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebMode_Upload);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'WebMode.upload()';
}


}




/// @nodoc


class WebMode_Duplex extends WebMode {
  const WebMode_Duplex({required final  Map<String, FileDto> files, this.pin, required this.allowUpload}): _files = files,super._();


 final  Map<String, FileDto> _files;
 Map<String, FileDto> get files {
  if (_files is EqualUnmodifiableMapView) return _files;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_files);
}

 final  String? pin;
 final  bool allowUpload;

/// Create a copy of WebMode
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WebMode_DuplexCopyWith<WebMode_Duplex> get copyWith => _$WebMode_DuplexCopyWithImpl<WebMode_Duplex>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebMode_Duplex&&const DeepCollectionEquality().equals(other._files, _files)&&(identical(other.pin, pin) || other.pin == pin)&&(identical(other.allowUpload, allowUpload) || other.allowUpload == allowUpload));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_files),pin,allowUpload);

@override
String toString() {
  return 'WebMode.duplex(files: $files, pin: $pin, allowUpload: $allowUpload)';
}


}

/// @nodoc
abstract mixin class $WebMode_DuplexCopyWith<$Res> implements $WebModeCopyWith<$Res> {
  factory $WebMode_DuplexCopyWith(WebMode_Duplex value, $Res Function(WebMode_Duplex) _then) = _$WebMode_DuplexCopyWithImpl;
@useResult
$Res call({
 Map<String, FileDto> files, String? pin, bool allowUpload
});




}
/// @nodoc
class _$WebMode_DuplexCopyWithImpl<$Res>
    implements $WebMode_DuplexCopyWith<$Res> {
  _$WebMode_DuplexCopyWithImpl(this._self, this._then);

  final WebMode_Duplex _self;
  final $Res Function(WebMode_Duplex) _then;

/// Create a copy of WebMode
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? files = null,Object? pin = freezed,Object? allowUpload = null,}) {
  return _then(WebMode_Duplex(
files: null == files ? _self._files : files // ignore: cast_nullable_to_non_nullable
as Map<String, FileDto>,pin: freezed == pin ? _self.pin : pin // ignore: cast_nullable_to_non_nullable
as String?,allowUpload: null == allowUpload ? _self.allowUpload : allowUpload // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
