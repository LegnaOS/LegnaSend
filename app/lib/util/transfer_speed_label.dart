import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';

String transferSpeedValue(int? bytesPerSecond) => bytesPerSecond == null ? '—' : '${bytesPerSecond.asReadableFileSize}/s';
String currentTransferSpeedLabel(int? bytesPerSecond) =>
    bytesPerSecond == null ? t.transferSpeed.measuring : t.transferSpeed.current(speed: transferSpeedValue(bytesPerSecond));
