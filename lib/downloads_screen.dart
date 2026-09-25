import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'details.dart';
import 'downloads.dart';
import 'sources.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

/// Downloaded and downloading episodes, grouped by show, with filters for what needs attention.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.onBrowse});

  /// Where the empty state's button goes to find something to download.
  final VoidCallback? onBrowse;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  static const _filters = <String, Set<DownloadStatus>>{
    'All': {...DownloadStatus.values},
    'In progress': {DownloadStatus.queued, DownloadStatus.downloading},
    'Failed': {DownloadStatus.failed},
    'Done': {DownloadStatus.done},
  };
  String filter = 'All';

  /// Shows whose expanded state the user flipped from the default.
  final toggled = <Object?>{};

  @override
  void initState() {
    super.initState();
    Analytics.screen('/downloads', title: 'Downloads');
  }

  Future<void> _deleteShow(List<Download> group) async {
    final ok = await confirmDestructive(
      context,
      title: 'Delete ${group.length} downloads?',
      message:
          '${titleOf(group.first.media)} · '
          '${formatBytes(group.fold(0, (sum, d) => sum + d.bytes))} will be freed on this device.',
      action: 'Delete',
    );
    if (!ok) return;
    for (final d in [...group]) {
      await Downloads.instance.remove(d);
    }
    if (mounted) showSuccess(context, 'Downloads deleted');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Downloads'),
      toolbarHeight: isTv ? 72 : 64,
      titleSpacing: side,
      titleTextStyle: Theme.of(context).textTheme.headlineMedium,
    ),
    body: ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
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
        final shows = <Object?, List<Download>>{};
        for (final d in items) {
          shows.putIfAbsent(d.media['id'], () => []).add(d);
        }
        // The last failed or active download finished: fall back to everything.
        if (!items.any((d) => _filters[filter]!.contains(d.status))) {
          filter = 'All';
        }
        final wanted = _filters[filter]!;
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: Text(
                '${items.length} episodes · ${formatBytes(Downloads.instance.totalBytes)} on this device',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(side, 12, side, 4),
                children: [
                  for (final MapEntry(key: name, value: statuses)
                      in _filters.entries)
                    if (name == 'All' ||
                        items.any((d) => statuses.contains(d.status)))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            '$name · ${items.where((d) => statuses.contains(d.status)).length}',
                          ),
                          selected: filter == name,
                          onSelected: (_) => setState(() => filter = name),
                        ),
                      ),
                ],
              ),
            ),
            for (final MapEntry(key: id, value: group) in shows.entries)
              if (group.any((d) => wanted.contains(d.status)))
                _show(id, group, single: shows.length == 1),
          ],
        );
      },
    ),
  );

  Widget _show(Object? id, List<Download> group, {required bool single}) {
    final wanted = _filters[filter]!;
    // Open by default when there's something to act on, a single show, or a filter narrowing things down.
    final open =
        (filter != 'All' ||
            single ||
            group.any((d) => d.status != DownloadStatus.done)) !=
        toggled.contains(id);
    return Column(
      children: [
        _ShowHeader(
          group,
          expanded: open,
          onToggle: () => setState(
            () => toggled.contains(id) ? toggled.remove(id) : toggled.add(id),
          ),
          onDelete: () => _deleteShow(group),
        ),
        if (open)
          for (final d in [
            for (final d in group)
              if (wanted.contains(d.status)) d,
          ]..sort((a, b) => a.number.compareTo(b.number)))
            _DownloadTile(d, group),
      ],
    );
  }
}

class _ShowHeader extends StatelessWidget {
  const _ShowHeader(
    this.group, {
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
  });

  final List<Download> group;
  final bool expanded;
  final VoidCallback onToggle, onDelete;

  @override
  Widget build(BuildContext context) {
    final media = group.first.media;
    return ListTile(
      contentPadding: EdgeInsets.fromLTRB(side, 8, side - 12, 0),
      onTap: onToggle,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(radiusMedium),
        child: SizedBox(
          width: 40,
          height: 56,
          child: Artwork(Show(media).cover, color: Show(media).color),
        ),
      ),
      title: Text(
        titleOf(media),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text(
        '${group.length} ${group.length == 1 ? 'episode' : 'episodes'} · '
        '${formatBytes(group.fold(0, (sum, d) => sum + d.bytes))}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
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
  const _DownloadTile(this.download, this.group);

  final Download download;
  final List<Download> group;

  @override
  Widget build(BuildContext context) {
    final d = download;
    final failed = d.status == DownloadStatus.failed;
    final active =
        d.status == DownloadStatus.downloading ||
        d.status == DownloadStatus.queued;
    final status = switch (d.status) {
      DownloadStatus.queued => 'Waiting to download',
      DownloadStatus.downloading =>
        '${(d.progress * 100).round()}% · ${formatBytes(d.bytes)}',
      DownloadStatus.done =>
        '${formatBytes(d.bytes)} · ${d.dub ? 'Dub' : 'Sub'} · ${d.source}',
      DownloadStatus.failed => d.error ?? 'Download failed',
    };
    return ListTile(
      contentPadding: EdgeInsets.fromLTRB(side, 0, side - 12, 0),
      onTap: d.status == DownloadStatus.done
          ? () => playDownload(context, d, group)
          : null,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(radiusMedium),
        child: SizedBox(
          width: 88,
          height: 50,
          child: Artwork(
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
        ),
      ),
      title: Text(
        'Episode ${epNumber(d.number)}${d.title == null ? '' : ' · ${d.title}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            status,
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
      trailing: switch (d.status) {
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
