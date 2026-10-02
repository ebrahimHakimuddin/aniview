import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'details.dart';
import 'downloads.dart';
import 'downloads_view.dart';
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
  String filter = 'All';

  /// Shows whose expanded state the user flipped from the default.
  final toggled = <Object?>{};

  @override
  void initState() {
    super.initState();
    Analytics.screen('/downloads', title: 'Downloads');
  }

  Future<void> _deleteShow(List<Download> group) => confirmDeleteDownloads(
    context,
    [...group],
    show: titleOf(group.first.media),
  );

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
        final view = DownloadsView(items, filter: filter, toggled: toggled);
        filter = view.filter;
        return ListView(
          padding: EdgeInsets.only(
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
          ),
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
            for (final show in view.shows) _show(show),
          ],
        );
      },
    ),
  );

  Widget _show(ShowDownloads show) => Column(
    children: [
      _ShowHeader(
        show,
        onToggle: () => setState(
          () => toggled.contains(show.id)
              ? toggled.remove(show.id)
              : toggled.add(show.id),
        ),
        onDelete: () => _deleteShow(show.all),
      ),
      if (show.open)
        for (final d in show.shown) _DownloadTile(d, show.all),
    ],
  );
}

class _ShowHeader extends StatelessWidget {
  const _ShowHeader(
    this.show, {
    required this.onToggle,
    required this.onDelete,
  });

  final ShowDownloads show;
  final VoidCallback onToggle, onDelete;

  @override
  Widget build(BuildContext context) {
    final media = show.media;
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
      subtitle: Text(show.summary),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            show.open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
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
