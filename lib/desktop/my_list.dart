import 'package:flutter/material.dart';

import '../anilist.dart';
import '../details.dart';
import '../home_feed.dart';
import '../selection.dart';
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';
import 'widgets.dart';

/// Desktop My list: your AniList lists as tabs with their counts, searched, sorted and shown as a poster grid or a
/// table. Pick several (right click, or Select) to move or remove them together; the table steps a show's
/// progress by one from its row.
class DeskMyList extends StatefulWidget {
  const DeskMyList(
    this.feed, {
    super.key,
    required this.onReload,
    required this.onSignIn,
  });

  final HomeFeed feed;
  final void Function({bool force}) onReload;
  final VoidCallback onSignIn;

  @override
  State<DeskMyList> createState() => _DeskMyListState();
}

enum _Sort {
  list('List order'),
  title('Title'),
  score('Score'),
  progress('Progress');

  const _Sort(this.label);
  final String label;
}

class _DeskMyListState extends State<DeskMyList> {
  static const _all = '_all';

  String status = ListStatus.current.value;
  bool table = false, selecting = false;
  _Sort sort = _Sort.list;
  String filter = '';
  final picking = Picking();
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    picking.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    picking.dispose();
    _filter.dispose();
    super.dispose();
  }

  bool get _picking => selecting || picking.active;

  void _toggle(Map media) {
    selecting = true;
    picking.toggle(media);
  }

  void _done() {
    picking.clear();
    setState(() => selecting = false);
  }

  List _shown(Map<String, List> lists) {
    var shown = status == _all
        ? [for (final l in lists.values) ...l]
        : [...?lists[status]];
    final q = filter.trim().toLowerCase();
    if (q.isNotEmpty) {
      shown = [
        for (final m in shown)
          if (Show(m).title.toLowerCase().contains(q)) m,
      ];
    }
    switch (sort) {
      case _Sort.list:
        break;
      case _Sort.title:
        shown.sort((a, b) => Show(a).title.compareTo(Show(b).title));
      case _Sort.score:
        shown.sort((a, b) => (Show(b).score ?? 0) - (Show(a).score ?? 0));
      case _Sort.progress:
        shown.sort((a, b) => Show(b).progress - Show(a).progress);
    }
    return shown;
  }

  Future<void> _bulk(
    Future<bool> Function(Map media) change,
    String done,
  ) async {
    final result = await picking.runBulk(change);
    if (!mounted) return;
    result.ok
        ? showSuccess(context, bulkMessage(result, done))
        : showError(context, bulkMessage(result, done));
    setState(() => selecting = false);
    widget.onReload(force: true);
  }

  Future<void> _remove() async {
    final count = picking.count;
    final ok = await confirmDestructive(
      context,
      title: 'Remove $count from your list?',
      message: 'Their progress and status on AniList are deleted too.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    await _bulk((media) async {
      await Tracker.removeFromList(media);
      return true;
    }, 'Removed $count from your list');
  }

  @override
  Widget build(BuildContext context) {
    if (!Tracker.signedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DeskHeader('My list'),
          Expanded(
            child: EmptyState(
              icon: Icons.bookmarks_outlined,
              title: 'Sign in with AniList or MyAnimeList',
              message:
                  'Your watching, planning and completed shows show up here.',
              action: FilledButton(
                onPressed: widget.onSignIn,
                child: const Text('Sign in'),
              ),
            ),
          ),
        ],
      );
    }
    return FutureBuilder(
      future: widget.feed.library,
      builder: (context, snap) {
        final lists = snap.data ?? const <String, List>{};
        final total = lists.values.fold(0, (n, l) => n + l.length);
        final shown = _shown(lists);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(total, snap.hasData),
            _tabs(lists),
            const SizedBox(height: 8),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _body(snap, shown)),
                  if (_picking)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: _selectionBar(shown),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(int total, bool loaded) => DeskHeader(
    'My list',
    note: loaded ? '$total titles' : null,
    actions: [
      SizedBox(
        width: 240,
        child: TextField(
          controller: _filter,
          onChanged: (v) => setState(() => filter = v),
          decoration: InputDecoration(
            hintText: 'Search this list',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIcon: const Icon(Icons.filter_list_rounded, size: 20),
            suffixIcon: filter.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _filter.clear();
                      setState(() => filter = '');
                    },
                  ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<_Sort>(
        tooltip: 'Sort',
        initialValue: sort,
        onSelected: (v) => setState(() => sort = v),
        itemBuilder: (_) => [
          for (final s in _Sort.values)
            CheckedPopupMenuItem(
              value: s,
              checked: s == sort,
              child: Text(s.label),
            ),
        ],
        icon: const Icon(Icons.sort_rounded),
      ),
      IconButton(
        tooltip: table ? 'Show posters' : 'Show table',
        onPressed: () => setState(() => table = !table),
        icon: Icon(table ? Icons.grid_view_rounded : Icons.view_list_rounded),
      ),
      IconButton(
        tooltip: 'Select several',
        onPressed: () => setState(() => selecting = true),
        icon: const Icon(Icons.checklist_rounded),
      ),
    ],
  );

  /// The shared selection bar, floating over the foot of the list.
  Widget _selectionBar(List shown) => SelectionBar(
    count: picking.count,
    onDone: _done,
    busy: picking.busy,
    onAll: () => picking.selectAll(shown.cast<Map>()),
    actions: [
      PopupMenuButton<String>(
        enabled: picking.active && !picking.busy,
        tooltip: 'Move to',
        onSelected: (to) => _bulk(
          (m) => Tracker.save(m, Show(m).progress, status: to),
          'Moved ${picking.count} to ${ListStatus.labels[to]}',
        ),
        itemBuilder: (_) => [
          for (final MapEntry(:key, :value) in ListStatus.movable.entries)
            PopupMenuItem(value: key, child: Text(value)),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.drive_file_move_outline,
                color: picking.active
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              const Text('Move to'),
            ],
          ),
        ),
      ),
      TextButton.icon(
        onPressed: picking.active && !picking.busy ? _remove : null,
        style: TextButton.styleFrom(foregroundColor: scheme.error),
        icon: const Icon(Icons.delete_outline_rounded),
        label: const Text('Remove'),
      ),
    ],
  );

  Widget _tabs(Map<String, List> lists) {
    final entries = [
      (
        _all,
        'All',
        lists.values.fold<int?>(null, (n, l) => (n ?? 0) + l.length),
      ),
      for (final MapEntry(:key, :value) in ListStatus.movable.entries)
        (key, value, lists[key]?.length),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: deskMargin - 8),
        children: [
          for (final (key, label, count) in entries)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Hover(
                onTap: () {
                  if (key == status || picking.busy) return;
                  picking.clear();
                  setState(() => status = key);
                },
                builder: (context, hovered) => AnimatedContainer(
                  duration: motionMs(context, 120),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: key == status
                        ? scheme.primary.withValues(alpha: .16)
                        : hovered
                        ? scheme.onSurface.withValues(alpha: .07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(buttonRadius),
                  ),
                  child: Text(
                    count == null ? label : '$label · $count',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: key == status
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(AsyncSnapshot<Map<String, List>> snap, List shown) {
    if (snap.hasError) {
      return ErrorState(
        snap.error!,
        onRetry: () => widget.onReload(force: true),
      );
    }
    if (!snap.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (shown.isEmpty) {
      return EmptyState(
        icon: Icons.video_library_outlined,
        title: filter.isNotEmpty
            ? 'Nothing matches "$filter"'
            : 'Nothing ${status == _all ? 'on your list' : ListStatus.labels[status]!.toLowerCase()}',
      );
    }
    return table ? _table(shown) : _grid(shown);
  }

  Widget _grid(List shown) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(deskMargin, 12, deskMargin, 48),
    gridDelegate: const DeskPosterGrid(),
    itemCount: shown.length,
    itemBuilder: (context, i) {
      final poster = DeskPoster(
        shown[i],
        onChanged: () => widget.onReload(force: true),
        selected: _picking ? picking.has(shown[i]) : null,
        onToggle: () => _toggle(shown[i]),
      );
      return i < 18 ? Reveal(index: i, child: poster) : poster;
    },
  );

  Widget _table(List shown) => ListView.builder(
    padding: const EdgeInsets.fromLTRB(deskMargin, 4, deskMargin, 48),
    itemCount: shown.length,
    itemBuilder: (context, i) => _Row(
      shown[i],
      selected: _picking ? picking.has(shown[i]) : null,
      onToggle: () => _toggle(shown[i]),
      onChanged: () => widget.onReload(force: true),
    ),
  );
}

/// A show as a table row: its poster, title and facts, progress with a ＋1 on hover, score and list.
class _Row extends StatelessWidget {
  const _Row(
    this.media, {
    required this.selected,
    required this.onToggle,
    required this.onChanged,
  });

  final Map media;
  final bool? selected;
  final VoidCallback onToggle, onChanged;

  Future<void> _step(BuildContext context) async {
    final show = Show(media);
    final total = show.episodes;
    if (total != null && show.progress >= total) return;
    try {
      await Tracker.save(media, show.progress + 1, forwardOnly: true);
      onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final show = Show(media);
    final total = show.episodes ?? show.aired;
    final share = watchedShare(show.progress, total);
    return Hover(
      pressScale: .99,
      onTap: selected != null
          ? onToggle
          : () => openDetails(context, media, onBack: onChanged),
      onSecondary: (_) => onToggle(),
      builder: (context, hovered) => AnimatedContainer(
        duration: motionMs(context, 120),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected == true
              ? scheme.primary.withValues(alpha: .14)
              : hovered
              ? scheme.onSurface.withValues(alpha: .06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(nested(8, radiusMedium)),
        ),
        child: Row(
          children: [
            // Its room is always there, so the rows don't shift when picking starts.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Opacity(
                opacity: hovered || selected != null ? 1 : 0,
                child: PickBox(
                  picked: selected == true,
                  onTap: onToggle,
                  onDark: false,
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(radiusMedium),
              child: SizedBox(
                width: 44,
                height: 64,
                child: Artwork(show.cover, color: show.color),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    show.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    mediaMeta(media, genres: 2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EP ${show.progress}${total == null ? '' : ' / $total'}',
                          style: text.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: share,
                            minHeight: 4,
                            backgroundColor: scheme.onSurface.withValues(
                              alpha: .12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: AnimatedOpacity(
                      opacity: hovered && selected == null ? 1 : 0,
                      duration: motionMs(context, 120),
                      child: IconButton(
                        tooltip: 'Watched one more',
                        onPressed: hovered ? () => _step(context) : null,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                show.score == null ? '–' : '★ ${show.score}%',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                ListStatus.labels[show.listStatus] ?? '',
                textAlign: TextAlign.end,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
