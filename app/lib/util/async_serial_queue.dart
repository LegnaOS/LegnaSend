import 'dart:async';

/// Serializes asynchronous resource operations without poisoning the queue on failure.
/// Callers still receive their own error, but a later operation can recover.
class AsyncSerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
