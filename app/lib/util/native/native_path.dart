import 'package:path/path.dart' as path;

/// Locators are native paths, not URLs or protocol-relative file names.
/// In particular, a Windows rooted path (\foo) still depends on the process's
/// current drive. Never publish one as a durable workspace or download root.
bool isFullyQualifiedNativePath(String value, {required bool windows}) {
  if (value.isEmpty || value.contains('\x00')) return false;
  if (!windows) return path.posix.isAbsolute(value);
  final candidate = value.replaceAll('/', '\\');
  if (RegExp(r'^[a-zA-Z]:\\').hasMatch(candidate)) return true;
  if (candidate.startsWith(r'\\?\')) {
    final extended = candidate.substring(4);
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(extended)) return true;
    if (!extended.toUpperCase().startsWith(r'UNC\')) return false;
    return _isUncRoot(extended.substring(4));
  }
  if (!candidate.startsWith(r'\\') || candidate.startsWith(r'\\.\')) return false;
  return _isUncRoot(candidate.substring(2));
}

bool _isUncRoot(String value) {
  final parts = value.split('\\');
  return parts.length >= 2 && parts.take(2).every((part) => part.isNotEmpty && part != '.' && part != '..' && !part.contains(':'));
}
