import 'package:flutter/foundation.dart';

/// Things picked on a page for one change to all of them (shows, episodes), by [keyOf]. Nothing picked means
/// not picking. While a change is saving ([busy], see [runBulk]) the picks are held.
class Selection<K, V> extends ChangeNotifier {
  Selection(this.keyOf);

  final K Function(V item) keyOf;
  final _items = <K, V>{};
  bool _busy = false, _disposed = false;

  bool get busy => _busy;
  bool get active => _items.isNotEmpty;
  int get count => _items.length;

  /// The picks, in the order they were made.
  List<V> get items => _items.values.toList();

  bool has(V item) => _items.containsKey(keyOf(item));

  /// Picks [item], or unpicks it if it was; false (and nothing changes) while [busy].
  bool toggle(V item) {
    if (_busy) return false;
    final key = keyOf(item);
    if (_items.remove(key) == null) _items[key] = item;
    notifyListeners();
    return true;
  }

  /// Picks all of [every] (and nothing else).
  void selectAll(Iterable<V> every) {
    if (_busy) return;
    _items
      ..clear()
      ..addEntries([for (final item in every) MapEntry(keyOf(item), item)]);
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  /// Runs [change] on each pick, one at a time (AniList allows 30 requests a minute), then clears the picks. A
  /// change that returns false or throws counts as failed.
  Future<BulkResult> runBulk(Future<bool> Function(V item) change) async {
    final picks = items;
    _busy = true;
    notifyListeners();
    var failed = 0;
    for (final item in picks) {
      try {
        if (!await change(item)) failed++;
      } catch (_) {
        failed++;
      }
    }
    _busy = false;
    _items.clear();
    notifyListeners();
    return BulkResult(picks.length, failed);
  }

  @override
  void notifyListeners() {
    // The page may have closed mid-change.
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// How a [Selection.runBulk] went: [failed] of [total] weren't saved (queued for later, or failed).
class BulkResult {
  const BulkResult(this.total, this.failed);

  final int total, failed;

  bool get ok => failed == 0;
}

/// What to tell after a bulk change: [done] when every one went through, else how many didn't.
String bulkMessage(BulkResult result, String done) => result.ok
    ? done
    : '${result.failed} of ${result.total} not saved yet · they sync next time you open the app';
