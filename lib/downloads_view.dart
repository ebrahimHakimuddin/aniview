import 'downloads.dart';

/// The Downloads screen's decisions, apart from painting them: which filter applies, how downloads group by
/// show, which shows are open, and what each row says.
class DownloadsView {
  /// A filter that empties (the last failed or active download finished) falls back to everything.
  DownloadsView(this.items, {String filter = 'All', this.toggled = const {}})
    : filter = items.any((d) => filters[filter]!.contains(d.status))
          ? filter
          : 'All';

  static const filters = <String, Set<DownloadStatus>>{
    'All': {...DownloadStatus.values},
    'In progress': {DownloadStatus.queued, DownloadStatus.downloading},
    'Failed': {DownloadStatus.failed},
    'Done': {DownloadStatus.done},
  };

  final List<Download> items;
  final String filter;

  /// Shows (by media id) whose expanded state the user flipped from the default.
  final Set<Object?> toggled;

  Set<DownloadStatus> get wanted => filters[filter]!;

  /// The filter chips: each filter with something in it (always "All") and how many downloads it holds.
  List<(String, int)> get chips => [
    for (final MapEntry(key: name, value: statuses) in filters.entries)
      if (name == 'All' || items.any((d) => statuses.contains(d.status)))
        (name, items.where((d) => statuses.contains(d.status)).length),
  ];

  /// The shows with something under the current filter, in the order their first download was added.
  List<ShowDownloads> get shows {
    final byShow = <Object?, List<Download>>{};
    for (final d in items) {
      byShow.putIfAbsent(d.media['id'], () => []).add(d);
    }
    return [
      for (final MapEntry(key: id, value: group) in byShow.entries)
        if (group.any((d) => wanted.contains(d.status)))
          ShowDownloads(
            id,
            group,
            shown: [
              for (final d in group)
                if (wanted.contains(d.status)) d,
            ]..sort((a, b) => a.number.compareTo(b.number)),
            // Open by default when there's something to act on, a single show, or a filter narrowing things down.
            open:
                (filter != 'All' ||
                    byShow.length == 1 ||
                    group.any((d) => d.status != DownloadStatus.done)) !=
                toggled.contains(id),
          ),
    ];
  }

  /// What a row says under its title.
  static String statusText(Download d) => switch (d.status) {
    DownloadStatus.queued => 'Waiting to download',
    DownloadStatus.downloading =>
      '${(d.progress * 100).round()}% · ${formatBytes(d.bytes)}',
    DownloadStatus.done =>
      '${formatBytes(d.bytes)} · ${d.dub ? 'Dub' : 'Sub'} · ${d.source}',
    DownloadStatus.failed => d.error ?? 'Download failed',
  };
}

/// One show's downloads: [all] of them, and the [shown] ones under the filter, in episode order.
class ShowDownloads {
  ShowDownloads(this.id, this.all, {required this.shown, required this.open});

  final Object? id;
  final List<Download> all, shown;
  final bool open;

  Map get media => all.first.media;

  /// "3 episodes · 1.2 GB"
  String get summary =>
      '${all.length} ${all.length == 1 ? 'episode' : 'episodes'} · '
      '${formatBytes(all.fold(0, (sum, d) => sum + d.bytes))}';
}
