import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:path/path.dart' as p;

void main() {
  const receipt = '11111111-1111-4111-8111-111111111111';
  test('new core-generated receipt has no candidate, published receipt retains its original UTC time', () {
    final fresh = ReceiveRecoveryTarget(path: null, receiptId: receipt);
    expect(fresh.completedAt, isNull);
    final published = ReceiveRecoveryTarget(path: '/approved/file.txt', receiptId: receipt, completedUnixMs: 123456789);
    expect(published.completedAt!.millisecondsSinceEpoch, 123456789);
    expect(published.completedAt!.isUtc, isTrue);
    expect(published.receiptId, fresh.receiptId);
  });
  test('malformed ownership metadata is not silently downgraded to automatic recovery', () {
    expect(() => ReceiveRecoveryTarget(path: null, receiptId: 'remote-resume-key'), throwsFormatException);
    expect(() => ReceiveRecoveryTarget(path: null, receiptId: receipt, completedUnixMs: 1), throwsFormatException);
    expect(() => ReceiveRecoveryTarget(path: '/approved/file', receiptId: receipt, completedUnixMs: -1), throwsFormatException);
  });
  test('candidate may retain an owned numbered name but never redirect to another directory', () {
    final posix = p.Context(style: p.Style.posix);
    expect(
      validateRecoveryCandidatePath(candidate: '/approved/child/file (2).txt', expectedDirectory: '/approved/child', pathContext: posix),
      '/approved/child/file (2).txt',
    );
    for (final candidate in ['/other/file.txt', '/approved/child/../file.txt', 'relative.txt', '/approved/child', '/approved/child/invalid\u0000']) {
      expect(
        () => validateRecoveryCandidatePath(candidate: candidate, expectedDirectory: '/approved/child', pathContext: posix),
        throwsFormatException,
      );
    }
  });
  test('Windows path identity and cache descendants are compared without URI conversion', () {
    final windows = p.Context(style: p.Style.windows);
    expect(
      validateRecoveryCandidatePath(
        candidate: r'C:\Downloads\Child\file.txt',
        expectedDirectory: r'c:\downloads\child',
        pathContext: windows,
        caseInsensitive: true,
      ),
      r'C:\Downloads\Child\file.txt',
    );
    expect(isReceiveCacheDestination(r'C:\Cache\receive', r'c:\cache', pathContext: windows, caseInsensitive: true), isTrue);
    expect(isReceiveCacheDestination(r'C:\CacheBackup', r'c:\cache', pathContext: windows, caseInsensitive: true), isFalse);
    expect(
      () => validateRecoveryCandidatePath(candidate: 'content://provider/tree/root', expectedDirectory: '/approved'),
      throwsFormatException,
    );
  });
}
