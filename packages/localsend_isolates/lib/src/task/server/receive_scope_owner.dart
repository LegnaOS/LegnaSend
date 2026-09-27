import 'dart:async';

import 'package:localsend_isolates/util/ios_receive_scope.dart';

/// Retiring closes admission immediately; acquired scope closes only after the
/// acquire operation and EVERY retained queue/probe/write/postprocess user drain.
class ReceiveScopeOwner {
  IosReceiveScopeLease? _lease;
  bool _started = false, _acquiring = false, _retired = false, _releasing = false;
  int _users = 0;
  final _closed = Completer<void>();

  bool get active => !_retired;
  bool get isExternal => _lease != null;
  int get activeUsers => _users;

  Future<void> acquire(Future<IosReceiveScopeLease?> Function() load) async {
    if (_started || _retired) throw StateError('Receive scope acquisition is no longer available');
    _started = true;
    _acquiring = true;
    try {
      _lease = await load();
    } finally {
      _acquiring = false;
      _tryClose();
    }
  }

  /// Reserve BEFORE enqueueing, not only when the queued callback starts.
  void Function() retain() {
    if (_retired) throw StateError('Receive scope admission is closed');
    _users++;
    var returned = false;
    return () {
      if (returned) return;
      returned = true;
      _users--;
      _tryClose();
    };
  }

  Future<void> retire() {
    _retired = true;
    _tryClose();
    return _closed.future;
  }

  void _tryClose() {
    if (!_retired || _acquiring || _users != 0 || _releasing) return;
    _releasing = true;
    unawaited(Future<void>.sync(() async => _lease?.release()).then(_closed.complete, onError: _closed.completeError));
  }
}

/// FRB may report an error before its final progress sender is dropped. Never
/// cancel the stream on first error: onDone is the lifetime boundary for scope.
Future<void> drainReceiveProgress(Stream<double> stream, void Function(double) onProgress) {
  final done = Completer<void>();
  Object? firstError;
  StackTrace? firstStack;
  void failed(Object error, StackTrace stack) {
    firstError ??= error;
    firstStack ??= stack;
  }

  try {
    stream.listen(
      (value) {
        try {
          onProgress(value);
        } catch (error, stack) {
          failed(error, stack);
        }
      },
      onError: failed,
      cancelOnError: false,
      onDone: () {
        if (firstError != null) {
          done.completeError(firstError!, firstStack);
        } else {
          done.complete();
        }
      },
    );
  } catch (error, stack) {
    done.completeError(error, stack);
  }
  return done.future;
}
