import 'package:flutter/foundation.dart';

/// Pages a fixed airing window, keeping existing shows when a later page fails.
class LatestEpisodes extends ChangeNotifier {
  LatestEpisodes({required this.fetch, int? before})
    : before = before ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final Future<(List<Map>, bool)> Function(int page, int before) fetch;
  final int before;
  final items = <Map>[];
  int _page = 1;
  bool loading = false, hasMore = true;
  Object? error;
  bool _disposed = false;

  Future<void> more() async {
    if (loading || !hasMore || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final (next, more) = await fetch(_page, before);
      if (_disposed) return;
      final seen = {for (final item in items) item['media']['id']};
      for (final item in next) {
        if (seen.add(item['media']['id'])) items.add(item);
      }
      _page++;
      hasMore = more;
    } catch (e) {
      if (!_disposed) error = e;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
