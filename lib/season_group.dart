import 'package:flutter/foundation.dart';

/// Walks prequel/sequel links without combining the entries' tracking identities.
class SeasonGroup extends ChangeNotifier {
  SeasonGroup(Map media, {required this.relations}) {
    _add(media);
  }

  final Future<List<(String, Map)>> Function(Map) relations;
  final _media = <Object, Map>{};
  final _pending = <Object>[];
  final _edges = <Object, Set<Object>>{};
  bool loading = false;
  Object? error;
  bool _disposed = false;

  bool get hasMore => _pending.isNotEmpty;

  void _add(Map media) {
    final id = media['id'];
    if (id == null || _media.containsKey(id)) return;
    _media[id] = media;
    _pending.add(id);
  }

  Future<void> loadMore() async {
    if (loading || !hasMore || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      // Bound each visit's network work. The user can continue a long franchise.
      for (var i = 0; i < 12 && _pending.isNotEmpty; i++) {
        final id = _pending.first;
        final links = await relations(_media[id]!);
        if (_disposed) return;
        _pending.removeAt(0);
        for (final (kind, media) in links) {
          if (kind != 'PREQUEL' && kind != 'SEQUEL') continue;
          final other = media['id'];
          if (other == null || other == id) continue;
          _add(media);
          final from = kind == 'PREQUEL' ? other : id;
          final to = kind == 'PREQUEL' ? id : other;
          (_edges[from] ??= {}).add(to);
        }
      }
    } catch (e) {
      if (!_disposed) {
        error = e; // Keep both the partial results and retry position.
      }
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  List<Map> get items {
    final remaining = _media.keys.toSet();
    final result = <Map>[];
    int compare(Object a, Object b) {
      final year = (_media[a]!['seasonYear'] as int? ?? 9999).compareTo(
        _media[b]!['seasonYear'] as int? ?? 9999,
      );
      return year != 0 ? year : '$a'.compareTo('$b');
    }

    while (remaining.isNotEmpty) {
      final ready =
          remaining
              .where(
                (id) => !remaining.any(
                  (other) =>
                      other != id && (_edges[other]?.contains(id) ?? false),
                ),
              )
              .toList()
            ..sort(compare);
      // Bad metadata can form a cycle. Still expose each entry exactly once.
      final id = ready.isNotEmpty
          ? ready.first
          : (remaining.toList()..sort(compare)).first;
      remaining.remove(id);
      result.add(_media[id]!);
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
