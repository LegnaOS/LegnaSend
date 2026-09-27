import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/workspace/workspace_draft_defaults.dart';

void main() {
  test('unused route defaults remain stable and unique', () {
    expect(nextWorkspaceSlug([]), 'workspace1');
    expect(nextWorkspaceSlug(['workspace1', 'workspace3']), 'workspace2');
  });
  test('folder names support POSIX, Windows, Android providers and Unicode', () {
    expect(workspaceFolderName('/Users/a/照片/'), '照片');
    expect(workspaceFolderName(r'C:\Users\a\Photos'), 'Photos');
    expect(workspaceFolderName('content://documents/tree/primary%3ADCIM%2FCamera'), 'Camera');
    expect(workspaceFolderName('/'), '');
    expect(workspaceFolderName('/path/${'🌿' * 80}').length, 120);
  });
}
