import 'package:localsend_isolates/util/workspace_password.dart';
import 'package:refena_flutter/refena_flutter.dart';

final workspacePasswordProvider = Provider<Future<String> Function(String)>((_) => deriveWorkspacePassword);
