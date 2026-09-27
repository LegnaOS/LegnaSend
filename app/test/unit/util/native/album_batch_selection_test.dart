import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/album_batch_selection.dart';

void main() {
  test('pages metadata, preserves existing selection and deduplicates IDs', () async {
    final calls = <int>[];
    final existing = ['old', 'a'];
    final result = await collectAlbumBatch<String>(
      existing: existing,
      loadPage: (page, size) async {
        calls.add(page);
        expect(size, 2);
        return [
          ['a', 'b'],
          ['b', 'c'],
          <String>[],
        ][page];
      },
      id: (s) => s,
      cancelled: () => false,
      pageSize: 2,
    );
    expect(result.selected, ['old', 'a', 'b', 'c']);
    expect(result.limited, false);
    expect(existing, ['old', 'a']);
    expect(calls, [0, 1, 2]);
  });
  test('999 item cap includes previous selection, never materializes originals', () async {
    var calls = 0;
    final result = await collectAlbumBatch<int>(
      existing: [-1],
      loadPage: (page, size) async {
        calls++;
        return List.generate(size, (i) => page * size + i);
      },
      id: (n) => '$n',
      cancelled: () => false,
    );
    expect(result.selected.length, 999);
    expect(calls, 8);
    expect(result.limited, true);
  });
  test('cancellation during pending page does not publish partial selection or request another page', () async {
    var cancelled = false, calls = 0;
    final page = Completer<List<String>>();
    final result = collectAlbumBatch<String>(
      existing: ['old'],
      loadPage: (_, _) {
        calls++;
        return page.future;
      },
      id: (s) => s,
      cancelled: () => cancelled,
    );
    final expectation = expectLater(result, throwsA(isA<AlbumBatchCancelled>()));
    cancelled = true;
    page.complete(['new']);
    await expectation;
    expect(calls, 1);
  });
  test('repeated provider pages are bounded even when every item is duplicate', () async {
    var calls = 0;
    final result = await collectAlbumBatch<String>(
      existing: [],
      loadPage: (_, _) async {
        calls++;
        return ['a', 'a'];
      },
      id: (s) => s,
      cancelled: () => false,
      pageSize: 2,
      maxPages: 3,
    );
    expect(calls, 3);
    expect(result.selected, ['a']);
    expect(result.limited, true);
  });
  test('provider errors leave caller selection unchanged', () async {
    final old = ['kept'];
    await expectLater(
      collectAlbumBatch<String>(existing: old, loadPage: (_, _) async => throw StateError('revoked'), id: (s) => s, cancelled: () => false),
      throwsStateError,
    );
    expect(old, ['kept']);
  });
  test('oversized page is rejected and full selection does not enumerate', () async {
    await expectLater(
      collectAlbumBatch<int>(existing: [], loadPage: (_, _) async => [1, 2, 3], id: (n) => '$n', cancelled: () => false, pageSize: 2),
      throwsStateError,
    );
    final result = await collectAlbumBatch<int>(
      existing: [1],
      loadPage: (_, _) async => throw StateError('must not run'),
      id: (n) => '$n',
      cancelled: () => false,
      maxSelected: 1,
    );
    expect(result.selected, [1]);
    expect(result.limited, true);
  });
}
