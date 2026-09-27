import 'package:localsend_isolates/rust/api/http.dart' as native;

/// Opaque native directory-and-lock lease. No capability data enters toString.
class SourceEndJournal {
  final native.RsSourceEndJournal _lease;
  SourceEndJournal._(this._lease);
  Future<String?> read() => _lease.read();
  Future<void> write(String data) => _lease.write(data: data);
  Future<void> close() => _lease.close();
  @override
  String toString() => 'SourceEndJournal(redacted)';
}

Future<SourceEndJournal> openSourceEndJournal(String path) async => SourceEndJournal._(await native.openSourceEndJournal(path: path));
