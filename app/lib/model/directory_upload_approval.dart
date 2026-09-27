enum DirectoryUploadApprovalStatus { waiting, responding, accepted, declined, expired, failed }

class DirectoryUploadApprovalFile {
  final String path;
  final int size;
  final bool directory;
  const DirectoryUploadApprovalFile({required this.path, required this.size, required this.directory});
}

/// Display-only immutable batch metadata. No destination root or credentials.
class DirectoryUploadApproval {
  final String requestId;
  final String workspaceId;
  final String workspaceName;
  final List<DirectoryUploadApprovalFile> files;
  final String peerIp;

  /// Server deadline as Unix milliseconds, not a new local waiting period.
  final int expiresAt;
  final DirectoryUploadApprovalStatus status;

  const DirectoryUploadApproval({
    required this.requestId,
    required this.workspaceId,
    required this.workspaceName,
    required this.files,
    required this.peerIp,
    required this.expiresAt,
    this.status = DirectoryUploadApprovalStatus.waiting,
  });

  bool get pending => status == DirectoryUploadApprovalStatus.waiting || status == DirectoryUploadApprovalStatus.responding;
  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);
  int get fileCount => files.where((file) => !file.directory).length;
  int get directoryCount => files.where((file) => file.directory).length;

  DirectoryUploadApproval withStatus(DirectoryUploadApprovalStatus value) => DirectoryUploadApproval(
    requestId: requestId,
    workspaceId: workspaceId,
    workspaceName: workspaceName,
    files: files,
    peerIp: peerIp,
    expiresAt: expiresAt,
    status: value,
  );
}
