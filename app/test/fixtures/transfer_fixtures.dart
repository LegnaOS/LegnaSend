import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';

FileDto transferFile(String id, int size) =>
    FileDto(id: id, fileName: '$id.bin', size: size, fileType: FileType.other, hash: null, preview: null, metadata: null);
CrossFile queuedFile(String id, int size) => CrossFile(
  name: '$id.bin',
  size: size,
  fileType: FileType.other,
  path: null,
  bytes: null,
  asset: null,
  thumbnail: null,
  lastModified: null,
  lastAccessed: null,
);
SendSessionState outgoing(String id, {SessionStatus status = SessionStatus.sending, int size = 100}) => SendSessionState(
  sessionId: id,
  remoteSessionId: 'remote-$id',
  background: true,
  status: status,
  target: Device.empty.copyWith(alias: 'Receiver'),
  files: {
    'out': SendingFile(file: transferFile('out', size), token: 'token', path: null, bytes: null, asset: null, thumbnail: null, errorMessage: null),
  },
  hashedFileCount: 1,
  startTime: null,
  endTime: null,
  sendingTasks: [],
  errorMessage: null,
);
ReceiveSessionState incoming(String id, {SessionStatus status = SessionStatus.sending, int size = 100}) => ReceiveSessionState(
  sessionId: id,
  status: status,
  sender: Device.empty.copyWith(alias: 'Sender'),
  senderAlias: 'Sender',
  files: {
    'in': ReceivingFile(
      file: transferFile('in', size),
      token: null,
      desiredName: status == SessionStatus.waiting ? null : 'in.bin',
      path: null,
      savedToGallery: false,
      errorMessage: null,
    ),
  },
  startTime: null,
  endTime: null,
  destinationDirectory: '/destination',
  cacheDirectory: '/cache',
  saveToGallery: false,
  createdDirectories: {},
);
