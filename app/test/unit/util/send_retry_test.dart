import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/util/send_retry.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  final files = List<CrossFile>.generate(5, (i) => queuedFile('file-$i', i + 1).copyWith(bytes: [i]));
  final job = SendJob(id: 'attempt', target: Device.empty, files: files, status: SendJobStatus.failed);
  final session = outgoing(job.id).copyWith(
    files: {
      for (var i = 0; i < files.length; i++)
        '$i': SendingFile(
          file: FileDto(
            id: '$i',
            fileName: files[i].name,
            size: files[i].size,
            fileType: files[i].fileType,
            hash: null,
            preview: null,
            metadata: null,
          ),
          token: 'old-token',
          thumbnail: null,
          asset: null,
          path: files[i].path,
          bytes: files[i].bytes,
          errorMessage: null,
        ),
    },
  );

  test('whole-file retry omits confirmed success and receiver skips, keeps failed queued and in-flight files', () {
    final statuses = [FileStatus.finished, FileStatus.skipped, FileStatus.failed, FileStatus.queue, FileStatus.sending];
    final remaining = remainingSendFiles(job, session, (id) => statuses[int.parse(id)]);
    expect(remaining, files.sublist(2));
    expect(identical(remaining.first, files[2]), isTrue);
  });
  test('missing preparation and unrelated or incomplete outcome snapshots never drop source files', () {
    expect(remainingSendFiles(job, null, (_) => FileStatus.finished), files);
    expect(remainingSendFiles(job, session.copyWith(sessionId: 'other'), (_) => FileStatus.finished), files);
    expect(remainingSendFiles(job, session.copyWith(files: {}), (_) => FileStatus.finished), files);
    expect(remainingSendFiles(job, session.copyWith(files: {'0': session.files['0']!}), (_) => FileStatus.finished), files);
    expect(
      remainingSendFiles(job, session.copyWith(files: Map.fromEntries(session.files.entries.toList().reversed)), (_) => FileStatus.finished),
      files,
    );
  });
  test('finished and deliberately skipped files do not produce an empty retry attempt', () {
    expect(remainingSendFiles(job, session, (_) => FileStatus.finished), isEmpty);
    expect(remainingSendFiles(job, session, (_) => FileStatus.skipped), isEmpty);
  });
  test('same-name files are selected by immutable source position not filename', () {
    final sameName = files.map((f) => f.copyWith(name: 'same.bin')).toList();
    final sameJob = SendJob(id: job.id, target: job.target, files: sameName);
    final sameSession = session.copyWith(
      files: {
        for (final entry in session.files.entries)
          entry.key: entry.value.copyWith(
            file: FileDto(
              id: entry.key,
              fileName: 'same.bin',
              size: entry.value.file.size,
              fileType: entry.value.file.fileType,
              hash: null,
              preview: null,
              metadata: null,
            ),
          ),
      },
    );
    final result = remainingSendFiles(sameJob, sameSession, (id) => id == '3' ? FileStatus.failed : FileStatus.finished);
    expect(result, [sameName[3]]);
  });
}
