import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'details.dart';
import 'downloads.dart';
import 'downloads_view.dart';
import 'platform.dart';
import 'selection.dart';
import 'sources.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

/// Downloaded and downloading episodes, grouped by show, with filters for what needs attention. A hold picks an
/// episode (a show's header, all of its episodes) for one change to all of them: delete, or retry the failed.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.onBrowse});

  /// Where the empty state's button goes to find something to download.
  final VoidCallback? onBrowse;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  String filter = 'All';

  /// Shows whose expanded state the user flipped from the default.
  final toggled = <Object?>{};

  /// Episodes picked for one change to all of them.
  final picked = Selection<String, Download>((d) => d.id);

  @override
  void initState() {
    super.initState();
    Analytics.screen('/downloads', title: 'Downloads');
  }

  @override
  void dispose() {
    picked.dispose();
    super.dispose();
  }

  void _pick(Download d) {
    if (picked.toggle(d)) selectionTick();
  }

  /// Picks all of [group], or unpicks it when it's all picked already.
  void _pickShow(List<Download> group) {
    final all = group.every(picked.has);
    picked.selectAll([
      for (final d in picked.items)
        if (!group.any((g) => g.id == d.id)) d,
      if (!all) ...group,
    ]);
    selectionTick();
  }

  /// The picks still in the list (one may have been cancelled, or finished, since it was picked).
  List<Download> get _picks => [
    for (final d in picked.items)
      if (Downloads.instance.items.contains(d)) d,
  ];

  Future<void> _deletePicked() async {
    if (await confirmDeleteDownloads(context, _picks) && mounted) {
      picked.clear();
    }
  }

  void _retryPicked(List<Download> failed) {
    for (final d in failed) {
      Downloads.instance.retry(d);
    }
    showSuccess(
      context,
      failed.length == 1
          ? 'Retrying 1 download'
          : 'Retrying ${failed.length} downloads',
    );
    picked.clear();
  }

  /// While picking: how many, All (what the filter shows), and delete, or retry the failed ones.
  Widget _selectionBar(List<Download> shown) {
    final picks = _picks;
    final failed = [
      for (final d in picks)
        if (d.status == DownloadStatus.failed) d,
    ];
    return SelectionBar(
      count: picks.length,
      onDone: picked.clear,
      onAll: shown.length > picks.length ? () => picked.selectAll(shown) : null,
      actions: [
        if (failed.isNotEmpty)
          IconButton(
            tooltip: 'Retry ${failed.length}',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _retryPicked(failed),
          ),
        IconButton(
          tooltip: 'Delete ${picks.length}',
          color: scheme.error,
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: picks.isEmpty ? null : _deletePicked,
        ),
      ],
    );
  }

  Future<void> _deleteShow(List<Download> group) => confirmDeleteDownloads(
    context,
    [...group],
    show: titleOf(group.first.media),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([picked, Downloads.instance]),
    builder: (context, _) {
      final picking = picked.active;
      final shown = _shown();
      return PopScope(
        canPop: !picking,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) picked.clear();
        },
        child: Scaffold(
          appBar: picking && !isDesktop
              ? AppBar(
                  automaticallyImplyLeading: false,
                  toolbarHeight: isTv ? 72 : 64,
                  titleSpacing: side - 8,
                  title: _selectionBar(shown),
                )
              : AppBar(
                  automaticallyImplyLeading: !isTv,
                  title: const Text('Downloads'),
                  toolbarHeight: isTv ? 72 : 64,
                  titleSpacing: side,
                  titleTextStyle: Theme.of(context).textTheme.headlineMedium,
                ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton: picking && isDesktop
              ? _selectionBar(shown)
              : null,
          body: _body(context, picking),
        ),
      );
    },
  );

  /// What the filter shows, every episode of it, for All.
  List<Download> _shown() {
    final items = Downloads.instance.items;
    if (items.isEmpty) return const [];
    return [
      for (final show in DownloadsView(
        items,
        filter: filter,
        toggled: toggled,
      ).shows)
        ...show.shown,
    ];
  }

  Widget _body(BuildContext context, bool picking) => Builder(
    builder: (context) {
      if (Downloads.instance.storageError != null) {
        return ErrorState(
          'Download storage is unavailable. Reconnect your folder, or change it in Settings.',
          onRetry: Downloads.instance.reconnect,
        );
      }
      final items = Downloads.instance.items;
      if (items.isEmpty) {
        return EmptyState(
          icon: Icons.download_for_offline_outlined,
          title: 'No downloads yet',
          message:
              '${isTv ? 'Hold OK on' : 'Long-press'} an episode, or use ⋮ → Download episodes on a show, to watch offline.',
          action: widget.onBrowse == null
              ? null
              : FilledButton.tonalIcon(
                  onPressed: widget.onBrowse,
                  icon: const Icon(Icons.explore_outlined),
                  label: const Text('Find something to watch'),
                ),
        );
      }
      final view = DownloadsView(items, filter: filter, toggled: toggled);
      filter = view.filter;
      // One row per show header or episode, built as it scrolls in. A change to the list rebuilds the rows in view;
      // a progress tick, only the totals and its own row's progress.
      final rows = <(ShowDownloads, Download?)>[
        for (final show in view.shows) ...[
          (show, null),
          if (show.open)
            for (final d in show.shown) (show, d),
        ],
      ];
      return ListView.builder(
        padding: EdgeInsets.only(
          bottom: 32 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: 2 + rows.length,
        itemBuilder: (context, i) => switch (i) {
          0 => Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: ListenableBuilder(
              listenable: Downloads.instance.ticks,
              builder: (context, _) => Text(
                '${items.length} episodes · ${formatBytes(Downloads.instance.totalBytes)} on this device',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          1 => SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(side, 12, side, 4),
              children: [
                for (final (name, count) in view.chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('$name · $count'),
                      selected: filter == name,
                      onSelected: (_) => setState(() => filter = name),
                    ),
                  ),
              ],
            ),
          ),
          _ => switch (rows[i - 2]) {
            (final show, null) => _ShowHeader(
              show,
              picked: picking ? show.shown.every(picked.has) : null,
              onToggle: picking
                  ? () => _pickShow(show.shown)
                  : () => setState(
                      () => toggled.contains(show.id)
                          ? toggled.remove(show.id)
                          : toggled.add(show.id),
                    ),
              onLongPress: () => _pickShow(show.shown),
              onDelete: () => _deleteShow(show.all),
            ),
            (final show, final d?) => _DownloadTile(
              d,
              show.all,
              picked: picking ? picked.has(d) : null,
              onPick: () => _pick(d),
            ),
          },
        },
      );
    },
  );
}

class _ShowHeader extends StatelessWidget {
  const _ShowHeader(
    this.show, {
    required this.onToggle,
    required this.onLongPress,
    required this.onDelete,
    this.picked,
  });

  final ShowDownloads show;
  final VoidCallback onToggle, onLongPress, onDelete;

  /// Picking several: whether all of the show's episodes shown are picked; null when not picking.
  final bool? picked;

  @override
  Widget build(BuildContext context) {
    final media = show.media;
    return ListTile(
      contentPadding: EdgeInsets.fromLTRB(side, 8, side - 12, 0),
      onTap: onToggle,
      onLongPress: onLongPress,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(radiusMedium),
        child: SizedBox(
          width: 40,
          height: 56,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(Show(media).cover, color: Show(media).color),
              if (picked != null)
                ...pickOverlay(picked!, radius: radiusMedium, leading: true),
            ],
          ),
        ),
      ),
      title: Text(
        titleOf(media),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: ListenableBuilder(
        listenable: Listenable.merge([for (final d in show.all) d.ticks]),
        builder: (context, _) => Text(show.summary),
      ),
      trailing: picked != null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  show.open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                MoreMenu(title: titleOf(media), [
                  (
                    icon: Icons.info_outline_rounded,
                    label: 'Open show',
                    onTap: () => openDetails(context, media),
                    destructive: false,
                  ),
                  (
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete all',
                    onTap: onDelete,
                    destructive: true,
                  ),
                ]),
              ],
            ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile(
    this.download,
    this.group, {
    required this.onPick,
    this.picked,
  });

  final Download download;
  final List<Download> group;
  final VoidCallback onPick;

  /// Picking several: whether this one is picked; null when not picking.
  final bool? picked;

  @override
  Widget build(BuildContext context) {
    final d = download;
    final failed = d.status == DownloadStatus.failed;
    final active =
        d.status == DownloadStatus.downloading ||
        d.status == DownloadStatus.queued;
    return ListTile(
      contentPadding: EdgeInsets.fromLTRB(side, 0, side - 12, 0),
      onTap: picked != null
          ? onPick
          : d.status == DownloadStatus.done
          ? () => playDownload(context, d, group)
          : null,
      onLongPress: onPick,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(radiusMedium),
        child: SizedBox(
          width: 88,
          height: 50,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(
                d.thumbnail,
                placeholder: Center(
                  child: Text(
                    epNumber(d.number),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (picked != null)
                ...pickOverlay(picked!, radius: radiusMedium, leading: true),
            ],
          ),
        ),
      ),
      title: Text(
        'Episode ${epNumber(d.number)}${d.title == null ? '' : ' · ${d.title}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // A progress tick redraws this, not the tile.
      subtitle: ListenableBuilder(
        listenable: d.ticks,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              DownloadsView.statusText(d),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: failed ? TextStyle(color: scheme.error) : null,
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: d.status == DownloadStatus.queued ? 0 : d.progress,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
      trailing: picked != null
          ? null
          : switch (d.status) {
              DownloadStatus.done => IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => confirmDeleteDownload(context, d),
              ),
              DownloadStatus.failed => IconButton(
                tooltip: 'Retry',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => Downloads.instance.retry(d),
              ),
              _ => IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Downloads.instance.remove(d),
              ),
            },
    );
  }
}
