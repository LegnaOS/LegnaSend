#!/usr/bin/env python3
"""Controllable original-v2 loopback fixture. Control is JSON stdin, never HTTP."""
import argparse
import hashlib
import http.client
import json
import select
import socket
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

PREFIX = '/api/localsend/v2/'
MAX_BYTES = 32 * 1024 * 1024
MAX_FILES = 128
MODES = {'accept', 'reject', 'hold', 'slow', 'fail-upload', 'checksum-once'}


def port_value(value):
    value = int(value)
    if not 1024 <= value <= 65535:
        raise ValueError('Use an unprivileged explicit loopback port: 1024..65535')
    return value


def fixture_bytes(size):
    if not 0 <= size <= MAX_BYTES:
        raise ValueError('Fixture size must be 0..32 MiB')
    block = bytes(range(251))
    return (block * (size // len(block) + 1))[:size]


class Peer:
    def __init__(self, port, output):
        self.port = port
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.log_lock = threading.Lock()
        self.slot = None
        self.mode = 'accept'
        self.delay_ms = 50
        self.sequence = 0
        self.sends = {}
        self.closed = threading.Event()
        self.log_file = (self.output / 'events.jsonl').open('a', encoding='utf-8')
        self.server = ThreadingHTTPServer(('127.0.0.1', port), self.handler())
        self.server.daemon_threads = True

    def log(self, event, **fields):
        record = {'time': time.time(), 'event': event, **fields}
        line = json.dumps(record, ensure_ascii=False)
        with self.log_lock:
            print(line, flush=True)
            self.log_file.write(line + '\n')
            self.log_file.flush()
        return record

    def info(self):
        return {'alias': 'LegnaSend loopback fixture', 'version': '2.2',
                'deviceModel': 'Loopback original-v2 fixture', 'deviceType': 'desktop',
                'fingerprint': hashlib.sha256(b'legnasend-loopback-v2-fixture').hexdigest().upper(),
                'port': self.port, 'protocol': 'http', 'download': False}

    def handler(self):
        peer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass

            def reply(self, status, body=None):
                data = b'' if body is None else json.dumps(body).encode()
                try:
                    self.send_response(status)
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    if data:
                        self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True

            def read_json(self):
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 256 * 1024:
                    raise ValueError('JSON body must be 1..256 KiB')
                return json.loads(self.rfile.read(size))

            def do_GET(self):
                if urlsplit(self.path).path == PREFIX + 'info':
                    self.reply(200, peer.info())
                else:
                    self.reply(404)

            def do_POST(self):
                parsed = urlsplit(self.path)
                try:
                    if parsed.path == PREFIX + 'register':
                        info = self.read_json()
                        peer.log('register_received', alias=info.get('alias'), advertisedPort=info.get('port'))
                        self.reply(200, peer.info())
                    elif parsed.path == PREFIX + 'prepare-upload':
                        self.prepare()
                    elif parsed.path == PREFIX + 'upload':
                        self.upload(parse_qs(parsed.query))
                    elif parsed.path == PREFIX + 'cancel':
                        query = parse_qs(parsed.query)
                        session_id = query.get('sessionId', [None])[0]
                        with peer.lock:
                            current = peer.slot
                            if current and (current['id'] == session_id or (session_id is None and current['pending'])):
                                current['cancelled'] = True
                                current['decision'].set()
                                peer.slot = None
                        peer.log('cancel_received', sessionId=session_id)
                        self.reply(200)
                    else:
                        self.reply(404)
                except Exception as error:
                    peer.log('request_error', path=parsed.path, error=str(error))
                    self.reply(400, {'error': str(error)})

            def prepare(self):
                request = self.read_json()
                if set(request) != {'info', 'files'}:
                    raise ValueError('Original prepare expects info and files')
                files = request['files']
                if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES:
                    raise ValueError('Fixture accepts 1..128 files')
                for file_id, file in files.items():
                    if file.get('id') != file_id or not isinstance(file.get('size'), int) or not 0 <= file['size'] <= MAX_BYTES:
                        raise ValueError('Invalid file identity/size')
                with peer.lock:
                    if peer.slot is not None:
                        self.reply(409)
                        return
                    mode = peer.mode
                    if mode == 'reject':
                        peer.log('prepare_rejected', files=len(files))
                        self.reply(403)
                        return
                    session = {'id': str(uuid.uuid4()), 'pending': True, 'cancelled': False,
                               'decision': threading.Event(), 'accepted': True, 'mode': mode,
                               'files': {key: {'metadata': value, 'token': str(uuid.uuid4()),
                                               'status': 'pending', 'attempts': 0} for key, value in files.items()}}
                    peer.slot = session
                peer.log('prepare_received', sessionId=session['id'], mode=mode,
                         files=[{'id': key, 'name': file['fileName'], 'bytes': file['size']} for key, file in files.items()])
                if mode == 'hold':
                    while not session['decision'].wait(.1):
                        if peer.closed.is_set():
                            session['cancelled'] = True
                            break
                        readable, _, _ = select.select([self.connection], [], [], 0)
                        if readable and not self.connection.recv(1, socket.MSG_PEEK):
                            with peer.lock:
                                if peer.slot is session:
                                    peer.slot = None
                            peer.log('prepare_disconnected', sessionId=session['id'])
                            return
                with peer.lock:
                    if session['cancelled'] or not session['accepted'] or peer.slot is not session:
                        if peer.slot is session:
                            peer.slot = None
                        self.reply(403)
                        return
                    session['pending'] = False
                self.reply(200, {'sessionId': session['id'], 'files': {key: value['token'] for key, value in session['files'].items()}})
                peer.log('prepare_accepted', sessionId=session['id'])

            def upload(self, query):
                if set(query) != {'sessionId', 'fileId', 'token'} or any(len(value) != 1 for value in query.values()):
                    self.reply(400)
                    return
                session_id, file_id, token = (query[key][0] for key in ('sessionId', 'fileId', 'token'))
                with peer.lock:
                    session = peer.slot
                    file = None if session is None else session['files'].get(file_id)
                    if (not session or session['id'] != session_id or session['pending'] or not file
                            or file['token'] != token or file['status'] != 'pending'):
                        self.reply(403)
                        peer.log('upload_invalid_token', sessionId=session_id, fileId=file_id)
                        return
                    file['status'] = 'uploading'
                    file['attempts'] += 1
                    peer.sequence += 1
                    destination = peer.output / f'received-{peer.sequence:04d}.bin'
                metadata = file['metadata']
                temporary = destination.with_suffix('.part')
                size, received, digest = metadata['size'], 0, hashlib.sha256()
                status = 500
                try:
                    if int(self.headers.get('Content-Length', '-1')) != size:
                        raise ValueError('Original upload length differs from offer')
                    peer.log('upload_started', sessionId=session_id, fileId=file_id, bytes=size, name=metadata['fileName'])
                    with temporary.open('xb') as out:
                        while received < size:
                            if session['cancelled'] or peer.closed.is_set():
                                raise ValueError('Transfer cancelled')
                            chunk = self.rfile.read(min(16384, size - received))
                            if not chunk:
                                raise ValueError('Partial request body disconnected')
                            out.write(chunk)
                            digest.update(chunk)
                            received += len(chunk)
                            if session['mode'] == 'slow':
                                time.sleep(peer.delay_ms / 1000)
                    mismatch = metadata.get('sha256') and metadata['sha256'].lower() != digest.hexdigest()
                    forced_checksum = session['mode'] == 'checksum-once' and file['attempts'] == 1
                    if mismatch or forced_checksum:
                        status = 422
                    elif session['mode'] == 'fail-upload':
                        status = 500
                    else:
                        with peer.lock:
                            if session['cancelled'] or peer.slot is not session:
                                raise ValueError('Cancelled before publication')
                            temporary.rename(destination)
                        status = 200
                        record = {'sessionId': session_id, 'fileId': file_id, 'name': metadata['fileName'],
                                  'bytes': received, 'sha256': digest.hexdigest(), 'path': str(destination)}
                        destination.with_suffix('.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
                        peer.log('file_saved', **record)
                except Exception as error:
                    peer.log('upload_failed', sessionId=session_id, fileId=file_id, bytes=received, error=str(error))
                finally:
                    if temporary.exists():
                        temporary.unlink()
                    with peer.lock:
                        file['status'] = 'pending' if status == 422 and file['attempts'] < 3 else ('finished' if status == 200 else 'failed')
                        if peer.slot is session and all(item['status'] in {'finished', 'failed'} for item in session['files'].values()):
                            peer.slot = None
                    self.reply(status)
                    peer.log('upload_result', sessionId=session_id, fileId=file_id, status=status, bytes=received)

        return Handler

    def request(self, port, operation, body, query=None, timeout=300):
        connection = http.client.HTTPConnection('127.0.0.1', port_value(port), timeout=timeout)
        try:
            data = json.dumps(body).encode()
            connection.request('POST', PREFIX + operation + (('?' + urlencode(query)) if query else ''),
                               body=data, headers={'Content-Type': 'application/json', 'Content-Length': str(len(data))})
            response = connection.getresponse()
            contents = response.read()
            return response.status, json.loads(contents) if contents else None
        finally:
            connection.close()

    def send(self, command):
        target = port_value(command['port'])
        data = fixture_bytes(int(command.get('size', 4096)))
        name = str(command.get('name', 'loopback-fixture.bin'))
        if not name or len(name) > 128 or '/' in name or '\\' in name or name in {'.', '..'}:
            raise ValueError('Use a simple fixture filename')
        chunk_size = int(command.get('chunk_size', 16384))
        delay = int(command.get('delay_ms', 0))
        if not 1 <= chunk_size <= 1024 * 1024 or not 0 <= delay <= 5000:
            raise ValueError('Invalid bounded chunk size/delay')
        identifier = str(command.get('id') or uuid.uuid4())
        with self.lock:
            if len(self.sends) >= 4 or identifier in self.sends:
                raise ValueError('At most four unique active fixture sends')
            state = {'port': target, 'session': None, 'cancel': threading.Event(), 'resume': threading.Event(), 'connection': None}
            state['resume'].set()
            self.sends[identifier] = state

        def run():
            try:
                file_id = str(uuid.uuid4())
                metadata = {'id': file_id, 'fileName': name, 'size': len(data), 'fileType': 'application/octet-stream',
                            'sha256': hashlib.sha256(data).hexdigest()}
                self.log('send_preparing', id=identifier, targetPort=target, name=name, bytes=len(data), sha256=metadata['sha256'])
                query = {'pin': str(command['pin'])} if 'pin' in command else None
                status, response = self.request(target, 'prepare-upload', {'info': self.info(), 'files': {file_id: metadata}}, query)
                self.log('send_prepare_result', id=identifier, status=status)
                if status != 200:
                    return
                state['session'] = response['sessionId']
                if state['cancel'].is_set():
                    self.request(target, 'cancel', {}, {'sessionId': state['session']}, timeout=5)
                    return
                token = response['files'].get(file_id)
                if not token:
                    self.log('send_skipped', id=identifier)
                    return
                connection = http.client.HTTPConnection('127.0.0.1', target, timeout=300)
                state['connection'] = connection
                connection.putrequest('POST', PREFIX + 'upload?' + urlencode({'sessionId': state['session'], 'fileId': file_id, 'token': token}))
                connection.putheader('Content-Length', str(len(data)))
                connection.endheaders()
                self.log('send_body_started', id=identifier, sessionId=state['session'])
                for offset in range(0, len(data), chunk_size):
                    while not state['resume'].wait(.1):
                        if state['cancel'].is_set():
                            raise ValueError('Fixture send cancelled')
                    if state['cancel'].is_set():
                        raise ValueError('Fixture send cancelled')
                    connection.send(data[offset:offset + chunk_size])
                    if command.get('hold_body') and offset == 0:
                        state['resume'].clear()
                        self.log('send_body_paused', id=identifier, bytes=min(chunk_size, len(data)))
                    if delay:
                        time.sleep(delay / 1000)
                result = connection.getresponse()
                result.read()
                self.log('send_finished', id=identifier, status=result.status, bytes=len(data), sha256=metadata['sha256'])
            except Exception as error:
                self.log('send_error', id=identifier, error=str(error))
            finally:
                if state['connection']:
                    state['connection'].close()
                with self.lock:
                    self.sends.pop(identifier, None)

        threading.Thread(target=run, daemon=True).start()
        return identifier

    def command(self, command):
        operation = command.get('op')
        if operation == 'mode':
            if command['value'] not in MODES:
                raise ValueError('Unknown mode')
            delay = int(command.get('delay_ms', 50))
            if not 0 <= delay <= 5000:
                raise ValueError('delay_ms must be 0..5000')
            with self.lock:
                self.mode, self.delay_ms = command['value'], delay
            self.log('mode_changed', mode=self.mode, delayMs=delay)
        elif operation == 'decision':
            with self.lock:
                if not self.slot or not self.slot['pending']:
                    raise ValueError('No pending approval')
                self.slot['accepted'] = command.get('accept') is True
                self.slot['decision'].set()
        elif operation == 'register':
            status, _ = self.request(command['port'], 'register', self.info(), timeout=5)
            self.log('registered_to_app', targetPort=command['port'], status=status)
        elif operation == 'send':
            self.send(command)
        elif operation in {'pause-send', 'resume-send', 'cancel-send'}:
            with self.lock:
                state = self.sends.get(str(command['id']))
            if not state:
                raise ValueError('Unknown active send id')
            if operation == 'pause-send':
                state['resume'].clear()
            elif operation == 'resume-send':
                state['resume'].set()
            else:
                state['cancel'].set()
                state['resume'].set()
                connection = state['connection']
                if connection and connection.sock:
                    connection.sock.shutdown(socket.SHUT_RDWR)
                query = {'sessionId': state['session']} if state['session'] else None
                status, _ = self.request(state['port'], 'cancel', {}, query, timeout=5)
                self.log('send_cancel_result', id=command['id'], status=status)
        elif operation == 'status':
            with self.lock:
                self.log('status', mode=self.mode, sessionId=None if self.slot is None else self.slot['id'],
                         pending=False if self.slot is None else self.slot['pending'], sends=list(self.sends))
        elif operation == 'stop':
            self.close()
        else:
            raise ValueError('Unknown stdin operation')

    def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        with self.lock:
            if self.slot:
                self.slot['cancelled'] = True
                self.slot['decision'].set()
            for state in self.sends.values():
                state['cancel'].set()
                state['resume'].set()
        self.server.shutdown()
        self.server.server_close()
        self.log('stopped')

    def run(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.log('ready', host='127.0.0.1', port=self.port, output=str(self.output), pid=__import__('os').getpid())
        try:
            for line in sys.stdin:
                try:
                    self.command(json.loads(line))
                except Exception as error:
                    self.log('control_error', error=str(error))
                if self.closed.is_set():
                    break
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=port_value, default=26661)
    parser.add_argument('--output', default='build/test-results/batch30/loopback-peer/runtime')
    args = parser.parse_args()
    Peer(args.port, args.output).run()


if __name__ == '__main__':
    main()
