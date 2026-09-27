import 'package:localsend_isolates/rust/api/server.dart' as rust;

/// Password derivation runs on Rust's bounded worker pool, not Flutter's UI thread.
Future<String> deriveWorkspacePassword(String password) => rust.hashDirectoryPassword(password: password);
