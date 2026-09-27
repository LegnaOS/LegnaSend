/// Bounded metadata-only album enumeration. No original image bytes are read.
class AlbumBatchResult<T> {
  final List<T> selected;
  final bool limited;
  const AlbumBatchResult(this.selected, {required this.limited});
}

class AlbumBatchCancelled implements Exception {}

Future<AlbumBatchResult<T>> collectAlbumBatch<T>({
  required List<T> existing,
  required Future<List<T>> Function(int page, int size) loadPage,
  required String Function(T) id,
  required bool Function() cancelled,
  void Function(int selected)? onProgress,
  int maxSelected = 999,
  int pageSize = 128,
  int maxPages = 64,
}) async {
  if (maxSelected < 1 || pageSize < 1 || maxPages < 1) throw ArgumentError('Invalid album budget');
  final selected = <T>[];
  final ids = <String>{};
  for (final item in existing) {
    if (ids.add(id(item))) selected.add(item);
  }
  if (selected.length > maxSelected) throw ArgumentError('Existing selection exceeds limit');
  for (var page = 0; page < maxPages; page++) {
    if (cancelled()) throw AlbumBatchCancelled();
    if (selected.length == maxSelected) return AlbumBatchResult(List.unmodifiable(selected), limited: true);
    final items = await loadPage(page, pageSize);
    if (cancelled()) throw AlbumBatchCancelled();
    if (items.length > pageSize) throw StateError('Provider exceeded requested page size');
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (ids.contains(id(item))) continue;
      if (selected.length == maxSelected) return AlbumBatchResult(List.unmodifiable(selected), limited: true);
      ids.add(id(item));
      selected.add(item);
    }
    onProgress?.call(selected.length);
    if (items.length < pageSize) return AlbumBatchResult(List.unmodifiable(selected), limited: false);
    // Yield between metadata pages so a cancellation can be observed.
    await Future<void>.delayed(Duration.zero);
  }
  return AlbumBatchResult(List.unmodifiable(selected), limited: true);
}
