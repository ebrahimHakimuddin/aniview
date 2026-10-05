import 'package:flutter/material.dart';

import '../anilist.dart';
import '../downloads.dart';
import '../history.dart';
import '../home_feed.dart';
import '../library.dart' show RecentlyWatchedScreen;
import '../search.dart';
import '../settings.dart';
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';
import 'widgets.dart';

/// Desktop Home: the trending banner across the top, then a row per section you've switched on in Settings, as
/// wide as the window allows.
class DeskHome extends StatelessWidget {
  const DeskHome(
    this.feed, {
    super.key,
    required this.onRefresh,
    required this.onReload,
    required this.onSignIn,
  });

  final HomeFeed feed;
  final Future<void> Function() onRefresh;
  final void Function({bool force}) onReload;
  final VoidCallback onSignIn;

  List<Map> get _downloaded => {
    for (final d in Downloads.instance.items)
      if (d.status == DownloadStatus.done) d.media['id']: d.media,
  }.values.toList();

  /// Takes [section] off Home, with the way back: Undo now, or Settings → Home screen later.
  void _hide(BuildContext context, HomeSection section) {
    final before = Settings.homeSections;
    Settings.homeSections = [
      for (final (s, shown) in before) (s, s == section ? false : shown),
    ];
    onReload();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          width: 480,
          content: Text(
            'Hid “${section.label}”. Settings → Home screen brings it back.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              Settings.homeSections = before;
              onReload();
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: feed.trending,
    builder: (context, trending) {
      final offline = trending.hasError && _downloaded.isNotEmpty;
      final featured = Settings.homeSections.contains((
        HomeSection.featured,
        true,
      ));
      return ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          if (offline) ...[
            _OfflineBanner(onRetry: onRefresh),
            _recent(context),
            DeskRow('Downloaded', _downloaded, onChanged: onReload),
          ] else ...[
            if (featured)
              Swap(
                child: KeyedSubtree(
                  key: ValueKey(trending.hasData || trending.hasError),
                  child: _hero(trending),
                ),
              ),
            if (!Tracker.signedIn) _SignInBanner(onSignIn),
            for (final (section, shown) in Settings.homeSections)
              if (shown && section != HomeSection.featured)
                _section(context, section, trending),
          ],
        ],
      );
    },
  );

  Widget _hero(AsyncSnapshot<List> trending) {
    if (trending.hasError) {
      return ErrorState(trending.error!, compact: true, onRetry: onRefresh);
    }
    if (!trending.hasData) {
      return const SizedBox(height: 380, child: Skeleton(radius: 0));
    }
    if (trending.data!.isEmpty) return const SizedBox.shrink();
    return DeskHero(
      items: trending.data!.take(6).toList(),
      onChanged: onReload,
    );
  }

  Widget _section(
    BuildContext context,
    HomeSection section,
    AsyncSnapshot<List> trending,
  ) {
    final showAiring = Settings.homeSections.contains((
      HomeSection.airing,
      true,
    ));
    switch (section) {
      case HomeSection.featured:
        return const SizedBox.shrink();
      case HomeSection.newEpisodes:
        return SwapFuture(
          future: feed.released,
          builder: (context, snap) {
            final aired = snap.data ?? const [];
            if (aired.isEmpty) return const SizedBox.shrink();
            return DeskRow(
              section.label,
              [for (final a in aired) a['media']],
              onChanged: onReload,
              onHide: () => _hide(context, section),
              subtitles: [
                for (final a in aired)
                  'EP ${a['episode']} · ${_ago(a['airingAt'] as int)}',
              ],
            );
          },
        );
      case HomeSection.recent:
        return _recent(context);
      case HomeSection.season:
        final (name, year) = AniList.currentSeason;
        return _row(
          'This season · ${name[0]}${name.substring(1).toLowerCase()} $year',
          feed.season,
          context,
          section: section,
          seeAll: SearchFilters(
            season: name,
            year: year,
            sort: 'POPULARITY_DESC',
          ),
        );
      case HomeSection.trending:
        return _row(
          section.label,
          feed.trending,
          context,
          section: section,
          showError: !Settings.homeSections.contains((
            HomeSection.featured,
            true,
          )),
          seeAll: const SearchFilters(sort: 'TRENDING_DESC'),
        );
      case HomeSection.airing || HomeSection.watching || HomeSection.planning:
        if (!Tracker.signedIn) return const SizedBox.shrink();
        return SwapFuture(
          future: feed.lists,
          builder: (context, snap) {
            if (!snap.hasData && !snap.hasError) {
              return const _RowPlaceholder();
            }
            if (snap.hasError) {
              return ErrorState(snap.error!, compact: true, onRetry: onReload);
            }
            final rows = homeRows(
              snap.data!,
              splitAiring: showAiring,
              season: AniList.currentSeason,
            );
            final items = switch (section) {
              HomeSection.airing => rows.airing,
              HomeSection.planning => rows.planning,
              _ => rows.watching,
            };
            if (rows.empty && section == HomeSection.watching) {
              return const _EmptyList();
            }
            return items.isEmpty
                ? const SizedBox.shrink()
                : DeskRow(
                    section.label,
                    items,
                    onChanged: onReload,
                    onHide: () => _hide(context, section),
                  );
          },
        );
    }
  }

  Widget _recent(BuildContext context) => SwapFuture(
    future: feed.history,
    builder: (context, snap) {
      final records = snap.data ?? const <WatchRecord>[];
      if (records.isEmpty) return const SizedBox.shrink();
      return DeskResumeRow(
        'Continue watching',
        records,
        onChanged: onReload,
        onHide: () => _hide(context, HomeSection.recent),
        onSeeAll: () async {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const RecentlyWatchedScreen(),
            ),
          );
          onReload();
        },
      );
    },
  );

  Widget _row(
    String title,
    Future<List> future,
    BuildContext context, {
    required HomeSection section,
    bool showError = true,
    SearchFilters? seeAll,
  }) => SwapFuture(
    future: future,
    builder: (context, snap) {
      if (!snap.hasData && !snap.hasError) return const _RowPlaceholder();
      if (snap.hasError) {
        return showError
            ? ErrorState(snap.error!, compact: true, onRetry: onRefresh)
            : const SizedBox.shrink();
      }
      if (snap.data!.isEmpty) return const SizedBox.shrink();
      return DeskRow(
        title,
        snap.data!,
        onChanged: onReload,
        onSeeAll: seeAll == null ? null : () => openSearch(context, seeAll),
        onHide: () => _hide(context, section),
      );
    },
  );
}

/// "today", "yesterday" or "3d ago" for a unix time in the past.
String _ago(int airingAt) {
  final days = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(airingAt * 1000))
      .inDays;
  return switch (days) {
    0 => 'today',
    1 => 'yesterday',
    _ => '${days}d ago',
  };
}

class _RowPlaceholder extends StatelessWidget {
  const _RowPlaceholder();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(deskMargin, 28, deskMargin, 0),
    child: SizedBox(
      height: deskPosterWidth * 1.5 + 40,
      // As many as fit; the rest are cut off, not an overflow.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < 8; i++)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: SizedBox(
                  width: deskPosterWidth,
                  child: const Align(
                    alignment: Alignment.topCenter,
                    child: AspectRatio(aspectRatio: 2 / 3, child: Skeleton()),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyList extends StatelessWidget {
  const _EmptyList();

  @override
  Widget build(BuildContext context) => const EmptyState(
    compact: true,
    icon: Icons.video_library_outlined,
    title: 'Your list is empty',
    message: 'Shows you watch or plan to watch show up here. Search above to find one.',
  );
}

class _SignInBanner extends StatelessWidget {
  const _SignInBanner(this.onTap);

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(deskMargin, 24, deskMargin, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(nested(8)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.sync_rounded, color: scheme.primary, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sign in with AniList', style: text.titleMedium),
                    Text(
                      'Track what you watch, and see your lists and stats here',
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton(onPressed: onTap, child: const Text('Sign in')),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(deskMargin, 24, deskMargin, 0),
    child: Row(
      children: [
        Icon(Icons.cloud_off_rounded, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            "You're offline · showing your downloads",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
