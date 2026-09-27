#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/legnasend-file-selection.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SRC="$ROOT/app/android/app/src/main/kotlin/org/localsend/localsend_app"
TEST="$ROOT/app/android/app/src/test/java/org/localsend/localsend_app"
javac --release 17 -d "$OUT" "$SRC/SafFolderTree.java" "$SRC/SafFileSelection.java" \
    "$TEST/SafFolderTreeTest.java" "$TEST/SafFileSelectionTest.java"
java -cp "$OUT" org.localsend.localsend_app.SafFileSelectionTest
java -cp "$OUT" org.localsend.localsend_app.SafFolderTreeTest
if [[ -n "${FLUTTER_EMBEDDING_JAR:-}" ]]; then
    javac --release 17 -cp "$OUT:$SDK/platforms/android-36/android.jar:$FLUTTER_EMBEDDING_JAR" -d "$OUT" \
        "$SRC/AndroidFileSelection.java"
    echo 'Android file selection: SDK 36 + Flutter embedding compilation passed (not a device test)'
fi
if [[ -n "${FLUTTER_EMBEDDING_JAR:-}" && -n "${KOTLIN_HOME:-}" && -n "${LIFECYCLE_COMMON_JAR:-}" ]]; then
    javac --release 17 -cp "$SDK/platforms/android-36/android.jar:$FLUTTER_EMBEDDING_JAR" -d "$OUT" "$SRC"/*.java
    "$KOTLIN_HOME/bin/kotlinc" "$SRC/MainActivity.kt" "$SRC/FastDocumentFile.kt" "$SRC/FileOpener.kt" \
        "$SRC/NetworkSignalReader.kt" "$SRC/NetworkRouteReader.kt" -jvm-target 17 \
        -classpath "$SDK/platforms/android-36/android.jar:$FLUTTER_EMBEDDING_JAR:$LIFECYCLE_COMMON_JAR:$OUT" -d "$OUT/activity.jar"
    echo 'Android activity: all native Java + Kotlin type-check passed (not an APK/device test)'
fi
python3 - "$SRC/MainActivity.kt" "$SRC/AndroidFileSelection.java" <<'PY'
import sys
activity, adapter = (open(p, encoding='utf-8').read() for p in sys.argv[1:])
branch = activity.split('REQUEST_CODE_PICK_FILE -> {', 1)[1].split('private fun openGallery()', 1)[0]
assert branch.index('pendingResult = null') < branch.index('fileSelection.read(')
assert 'takePersistableUriPermission' not in branch and 'FastDocumentFile' not in branch
assert 'fileSelection.close()' in activity
launch = activity.split('private fun launchPicker(', 1)[1].split('@SuppressLint', 1)[0]
assert launch.index('pendingResult = null') < launch.index('reply?.error(')
assert 'new ThreadPoolExecutor(2, 2,' in adapter and 'new ArrayBlockingQueue<Runnable>(2)' in adapter
assert 'resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)' in adapter
assert 'cursor.isNull(1) ? null : cursor.getLong(1)' in adapter
print('PASS picker ownership, worker bounds, read-only grant and unknown length source guards (not a device test)')
PY
