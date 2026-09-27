/// Integrity work is separate from transport bytes and resumable offsets.
class FileVerification {
  final String attemptId;
  final int verifiedBytes;
  final int totalBytes;
  final bool receiving;

  const FileVerification({required this.attemptId, required this.verifiedBytes, required this.totalBytes, this.receiving = true});

  bool get valid => attemptId.isNotEmpty && verifiedBytes >= 0 && totalBytes >= 0 && verifiedBytes <= totalBytes;
  double? get progress => totalBytes == 0 ? null : (verifiedBytes / totalBytes).clamp(0, 1);
}
