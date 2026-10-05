import 'package:flutter/material.dart';

import '../anilist.dart';
import '../details.dart';
import '../platform.dart' show AndroidApp;
import '../downloads.dart';
import '../downloads_view.dart';
import '../sources.dart' show epNumber;
import '../states.dart';
import '../ui.dart';
import 'widgets.dart';

/// Desktop Downloads: what's on this device as a card a show, its episodes as rows with their state and the
/// actions on hover, and filters for what needs attention.
class DeskDownloads extends StatefulWidget {
  const DeskDownloads({super.key, required this.onBrowse});

  /// Goes to Home, from the empty state.
  final VoidCallback onBrowse;

  @override
  State<DeskDownloads> createState() => _DeskDownloadsState();
}

class _DeskDownloadsState extends State<DeskDownloads> {
  String filter = 'All';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Downloads.instance,
    builder: (context, _) {
      final items = Downloads.instance.items;
      if (items.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DeskHeader('Downloads'),
            Expanded(
              child: EmptyState(
                icon: Icons.download_for_offline_outlined,
                title: 'No downloads yet',
                message: 'Right-click an episode, or use ⋮ → Download episodes on a show, to watch offline.',
                action: FilledButton.tonalIcon(
                  onPressed: widget.onBrowse,
                  icon: const Icon(Icons.explore_outlined),
                  label: const Text('Find something to watch'),
                ),
              ),
            ),
          ],
        );
      }
      final view = DownloadsView(items, filter: filter);
      filter = view.filter;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskHeader(
            'Downloads',
            note:
                '${items.length} episodes · ${formatBytes(Downloads.instance.totalBytes)} on this device',
            actions: [
              TextButton.icon(
                onPressed: () => AndroidApp.open(Downloads.instance.folder),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Show in folder'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => confirmDeleteDownloads(context, [...items]),
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Delete all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: deskMargin - 8),
              children: [
                for (final (name, count) in view.chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Hover(
                      onTap: () => setState(() => filter = name),
                      builder: (context, hovered) => AnimatedContainer(
                        duration: motionMs(context, 120),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: filter == name
                              ? scheme.primary.withValues(alpha: .16)
                              : hovered
                              ? scheme.onSurface.withValues(alpha: .07)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(buttonRadius),
                        ),
                        child: Text(
                          '$name · $count',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: filter == name
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                deskMargin,
                12,
                deskMargin,
                48,
              ),
              children: [for (final show in view.shows) _ShowCard(show)],
            ),
          ),
        ],
      );
    },
  );
}

class _ShowCard extends StatelessWidget {
  const _ShowCard(this.show);

  final ShowDownloads show;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = show.media;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(nested(8)),
          boxShadow: ringShadow(),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radiusMedium),
                    child: SizedBox(
                      width: 44,
                      height: 64,
                      child: Artwork(
                        Show(media).cover,
                        color: Show(media).color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titleOf(media),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                        Text(
                          show.summary,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => openDetails(context, media),
                    child: const Text('Open show'),
                  ),
                  IconButton(
                    tooltip: 'Delete all of this show',
                    onPressed: () => confirmDeleteDownloads(context, [
                      ...show.all,
                    ], show: titleOf(media)),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: hairline),
            for (final d in show.shown) _Episode(d, show.all),
          ],
        ),
      ),
    );
  }
}

class _Episode extends StatelessWidget {
  const _Episode(this.download, this.group);

  final Download download;
  final List<Download> group;

  @override
  Widget build(BuildContext context) {
    final d = download;
    final text = Theme.of(context).textTheme;
    final failed = d.status == DownloadStatus.failed;
    final active =
        d.status == DownloadStatus.downloading ||
        d.status == DownloadStatus.queued;
    final done = d.status == DownloadStatus.done;
    return Hover(
      pressScale: .99,
      onTap: done ? () => playDownload(context, d, group) : null,
      builder: (context, hovered) => AnimatedContainer(
        duration: motionMs(context, 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: hovered
            ? scheme.onSurface.withValues(alpha: .05)
            : Colors.transparent,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(radiusMedium),
              child: SizedBox(
                width: 96,
                height: 54,
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
                    if (done && hovered)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Episode ${epNumber(d.number)}${d.title == null ? '' : ' · ${d.title}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    DownloadsView.statusText(d),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: failed ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (active)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(
                        value: d.status == DownloadStatus.queued
                            ? 0
                            : d.progress,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
            if (done)
              IconButton(
                tooltip: 'Play',
                onPressed: () => playDownload(context, d, group),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            if (failed)
              IconButton(
                tooltip: 'Retry',
                onPressed: () => Downloads.instance.retry(d),
                icon: const Icon(Icons.refresh_rounded),
              ),
            IconButton(
              tooltip: done ? 'Delete' : 'Cancel',
              onPressed: done
                  ? () => confirmDeleteDownload(context, d)
                  : () => Downloads.instance.remove(d),
              icon: Icon(
                done ? Icons.delete_outline_rounded : Icons.close_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
