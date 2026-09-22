import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'tracker.dart';
import 'cloudflare.dart';
import 'downloads.dart';
import 'history.dart';
import 'notifications.dart';
import 'player.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';
import 'tv.dart';

const background = Color(0xFF0A0A0F);
const _sheet = Color(0xFF14141C);

Future<void> openDetails(
  BuildContext context,
  Map media, {
  VoidCallback? onBack,
  Object? heroTag,
}) async {
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailsScreen(media, heroTag: heroTag)),
  );
  onBack?.call();
}

Color? _hex(String? hex) => hex == null || hex.length != 7
    ? null
    : Color(int.parse('FF${hex.substring(1)}', radix: 16));

const _posterGrid = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 150,
  childAspectRatio: .46,
  crossAxisSpacing: 14,
  mainAxisSpacing: 16,
);

// ───────────────────────────── Home ─────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late Future<Map<String, dynamic>?> viewer = Tracker.viewer();
  late Future<Map<String, List>> lists = Tracker.lists();
  late Future<List> trending = Tracker.trending();
  late Future<List> season = Tracker.season();

  /// Where you stopped in each show, newest first; on-device, so it's there even when AniList isn't.
  late Future<List<Map<String, dynamic>>> history = WatchHistory.all();

  late Future<List<Map>> released = _released();

  /// New episodes of the shows on your watching list and the ones you watched recently.
  Future<List<Map>> _released() async {
    final watching = await lists.then(
      (l) => l['CURRENT'] ?? const [],
      onError: (Object _) => const [], // still check the recently watched ones
    );
    return AniList.airedThisWeek([
      for (final m in [...watching, for (final r in await history) r['media']])
        if (m['id'] is int) m['id'] as int,
    ]);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Analytics.screen('/', title: 'Home');
    _syncPending();
    _scheduleNotifications();
    EpisodeNotifications.listen(_openFromNotification);
    listenTv(
      resume: _resumeFromLauncher,
      search: () => _push(const SearchScreen(voice: true)),
    );
    checkForUpdate(context, quiet: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _railHome.dispose();
    _tvList.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncPending();
  }

  /// Pushes progress watched while offline once a tracker is reachable again.
  Future<void> _syncPending() async {
    final synced = await Tracker.syncPending();
    if (synced > 0 && mounted) {
      showSuccess(
        context,
        'Synced $synced offline ${synced == 1 ? 'update' : 'updates'}',
      );
      _reloadLists();
    }
  }

  void _reloadLists() {
    setState(() {
      lists = Tracker.lists();
      history = WatchHistory.all();
      released = _released();
    });
    _scheduleNotifications();
  }

  /// Home is the root route, so its context can open a show whenever a notification is tapped.
  Future<void> _openFromNotification(int id) async {
    Analytics.event('notification_open', {'media_id': id});
    try {
      final media = await AniList.media(id);
      if (mounted) await openDetails(context, media, onBack: _reloadLists);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// A show picked from the TV launcher's Continue watching row: straight back into the player, or its page
  /// when that can't happen (history cleared since, or the episode isn't reachable).
  Future<void> _resumeFromLauncher(int id) async {
    Analytics.event('watch_next_open', {'media_id': id});
    final record = (await WatchHistory.all())
        .where((r) => r['media']['id'] == id)
        .firstOrNull;
    if (!mounted) return;
    if (record == null) return _openFromNotification(id);
    Navigator.popUntil(context, (route) => route.isFirst);
    try {
      await resumeWatching(context, record);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _reloadLists();
  }

  /// Keeps the background new-episode check current with recently watched shows and the AniList sign-in.
  Future<void> _scheduleNotifications() async {
    final recent = await history;
    syncWatchNext(recent);
    if (Settings.episodeNotifications &&
        (Tracker.signedIn || recent.isNotEmpty)) {
      EpisodeNotifications.requestPermission();
    }
    await EpisodeNotifications.refresh([for (final r in recent) r['media']]);
  }

  Future<void> _refresh() async {
    setState(() {
      viewer = Tracker.viewer();
      lists = Tracker.lists();
      trending = Tracker.trending();
      season = Tracker.season();
      history = WatchHistory.all();
      released = _released();
    });
    _syncPending();
    _scheduleNotifications();
    try {
      await Future.wait([lists, trending, season]);
    } catch (_) {} // each section shows its own error state
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) _refresh();
  }

  Future<void> _signIn() async {
    if (AniList.clientId.isEmpty) {
      showError(
        context,
        'This build has no AniList client id (--dart-define=ANILIST_CLIENT_ID)',
      );
      return;
    }
    try {
      await AniList.login(context);
      if (!Tracker.signedIn) return; // closed without signing in
      final me = await AniList.viewer();
      Analytics.event('sign_in');
      if (mounted) {
        showSuccess(context, 'Signed in as ${me?['name'] ?? 'AniList user'}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _refresh();
  }

  void _push(Widget screen) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => screen),
  ).then((_) => mounted ? _reloadLists() : null);

  /// Netflix-style TV home: a side rail, a billboard for the focused show, and rows of posters under it.
  final _railHome = FocusNode();
  final _tvList = ScrollController();

  /// Back from anywhere on the TV home goes up to the rail first; from the rail it leaves the app.
  Widget _tvHome() => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (_railHome.hasFocus) {
        SystemNavigator.pop();
        return;
      }
      if (_tvList.hasClients) {
        _tvList.animateTo(
          0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
      _railHome.requestFocus();
    },
    child: Scaffold(
      backgroundColor: background,
      body: Row(
        children: [
          _TvRail(
            homeFocus: _railHome,
            onSearch: () => _push(const SearchScreen()),
            onDownloads: () => _push(const DownloadsScreen()),
            onSettings: _openSettings,
          ),
          Expanded(
            child: FutureBuilder(
              future: trending,
              builder: (context, snap) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * .42,
                    child: ValueListenableBuilder(
                      valueListenable: focusedMedia,
                      builder: (context, focused, _) {
                        final media = focused ?? snap.data?.firstOrNull;
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: media == null
                              ? const SizedBox.expand()
                              : _Billboard(media, key: ValueKey(media['id'])),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      controller: _tvList,
                      padding: const EdgeInsets.only(bottom: 48),
                      children: [
                        if (snap.hasError && _downloaded.isNotEmpty)
                          _Shelf(
                            'Downloaded',
                            _downloaded,
                            onBack: _reloadLists,
                          ),
                        for (final (section, shown) in Settings.homeSections)
                          if (shown && section != HomeSection.featured)
                            _section(section, snap),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (isTv) return _tvHome();
    return Scaffold(
      backgroundColor: background,
      floatingActionButton: FutureBuilder(
        future: history,
        builder: (context, snap) {
          final record = snap.data?.firstOrNull;
          if (record == null) return const SizedBox.shrink();
          return ContinueFab(
            title: 'Continue EP ${epNumber(record['episode'])}',
            subtitle: titleOf(record['media']),
            onPressed: () async {
              await resumeWatching(context, record);
              if (mounted) _reloadLists();
            },
          );
        },
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder(
          future: trending,
          builder: (context, snap) => ListView(
            padding: EdgeInsets.zero,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _TopBar(viewer: viewer, onSettings: _openSettings),
              // Offline: go straight to what can play.
              if (snap.hasError && _downloaded.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          "You're offline · showing your downloads",
                          style: TextStyle(fontSize: 13, color: Colors.white60),
                        ),
                      ),
                      TextButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                _recentlyWatched,
                _Shelf('Downloaded', _downloaded, onBack: _reloadLists),
              ] else
                for (final (section, shown) in Settings.homeSections)
                  if (shown) _section(section, snap),
              const SizedBox(
                height: 96,
              ), // room for the continue-watching button
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(HomeSection section, AsyncSnapshot<List> trendingSnap) {
    final showAiring = Settings.homeSections.contains((
      HomeSection.airing,
      true,
    ));
    return switch (section) {
      HomeSection.featured => _Hero(
        items: trendingSnap.data?.take(6).toList() ?? const [],
        loading: trendingSnap.connectionState != ConnectionState.done,
        error: trendingSnap.error,
        onRetry: _refresh,
      ),
      HomeSection.newEpisodes => FutureBuilder(
        future: released,
        builder: (context, snap) {
          final aired = snap.data ?? const [];
          if (aired.isEmpty) return const SizedBox.shrink();
          return _Shelf(
            section.label,
            [for (final a in aired) a['media']],
            onBack: _reloadLists,
            subtitles: [
              for (final a in aired)
                'EP ${a['episode']} · ${_ago(a['airingAt'] as int)}',
            ],
          );
        },
      ),
      HomeSection.airing when Tracker.signedIn => FutureBuilder(
        future: lists,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ShelfSkeleton(title: section.label);
          }
          final airing = (snap.data?['CURRENT'] ?? const [])
              .where(_airingNow)
              .toList();
          return airing.isEmpty
              ? const SizedBox.shrink()
              : _Shelf(section.label, airing, onBack: _reloadLists);
        },
      ),
      HomeSection.watching when !Tracker.signedIn => _SignInCard(
        onTap: _signIn,
      ),
      HomeSection.watching ||
      HomeSection.planning when Tracker.signedIn => FutureBuilder(
        future: lists,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ShelfSkeleton(title: section.label);
          }
          if (snap.hasError) {
            return section == HomeSection.planning
                ? const SizedBox.shrink() // shown once, by watching
                : _Section(
                    'Your list',
                    child: ErrorState(
                      snap.error!,
                      compact: true,
                      onRetry: _reloadLists,
                    ),
                  );
          }
          final watching = snap.data!['CURRENT'] ?? const [];
          final planning = snap.data!['PLANNING'] ?? const [];
          if (section == HomeSection.planning) {
            return planning.isEmpty
                ? const SizedBox.shrink()
                : _Shelf(section.label, planning, onBack: _reloadLists);
          }
          if (watching.isEmpty && planning.isEmpty) {
            return EmptyState(
              compact: true,
              icon: Icons.video_library_outlined,
              title: 'Your list is empty',
              message: 'Shows you watch or plan to watch show up here.',
              action: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
                icon: const Icon(Icons.search_rounded),
                label: const Text('Find a show'),
              ),
            );
          }
          // Airing ones have their own row when it's shown.
          final current = showAiring
              ? watching.where((m) => !_airingNow(m)).toList()
              : watching;
          return current.isEmpty
              ? const SizedBox.shrink()
              : _Shelf(section.label, current, onBack: _reloadLists);
        },
      ),
      HomeSection.recent => _recentlyWatched,
      HomeSection.season => _shelf(
        () {
          final (name, year) = AniList.currentSeason;
          return 'This season · ${name[0]}${name.substring(1).toLowerCase()} $year';
        }(),
        season,
        onRetry: () => setState(() => season = Tracker.season()),
        seeAll: SearchFilters(
          season: AniList.currentSeason.$1,
          year: AniList.currentSeason.$2,
          sort: 'POPULARITY_DESC',
        ),
      ),
      HomeSection.trending => _shelf(
        section.label,
        trending,
        onRetry: _refresh,
        // The banner already shows the error.
        showError: !Settings.homeSections.contains((
          HomeSection.featured,
          true,
        )),
        seeAll: const SearchFilters(sort: 'TRENDING_DESC'),
      ),
      _ => const SizedBox.shrink(), // list rows while signed out
    };
  }

  Widget get _recentlyWatched => FutureBuilder(
    future: history,
    builder: (context, snap) {
      final records = snap.data ?? const [];
      if (records.isEmpty) return const SizedBox.shrink();
      return _Shelf(
        'Recently watched',
        [for (final record in records) record['media']],
        onBack: _reloadLists,
        subtitles: [
          for (final r in records)
            'EP ${epNumber(r['episode'])}'
                '${(r['position'] as int? ?? 0) > 0 ? ' · ${formatDuration(Duration(milliseconds: r['position']))}' : ''}',
        ],
        onLongPress: (i) => _removeFromHistory(records[i]),
      );
    },
  );

  Future<void> _removeFromHistory(Map<String, dynamic> record) async {
    HapticFeedback.mediumImpact();
    final remove = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: _sheet,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.history_toggle_off_rounded),
          title: const Text('Remove from recently watched'),
          subtitle: Text(titleOf(record['media'])),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (remove != true) return;
    await WatchHistory.remove(record['media']);
    if (mounted) _reloadLists();
  }

  /// Shows with a finished download.
  List<Map> get _downloaded => {
    for (final d in Downloads.instance.items)
      if (d.status == DownloadStatus.done) d.media['id']: d.media,
  }.values.toList();

  Widget _shelf(
    String title,
    Future<List> future, {
    required VoidCallback onRetry,
    bool showError = true,
    SearchFilters? seeAll,
  }) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) {
        return ShelfSkeleton(title: title);
      }
      if (snap.hasError) {
        return showError
            ? _Section(
                title,
                child: ErrorState(snap.error!, compact: true, onRetry: onRetry),
              )
            : const SizedBox.shrink();
      }
      if (snap.data!.isEmpty) {
        return _Section(
          title,
          child: const Text(
            'Nothing here yet.',
            style: TextStyle(color: Colors.white70),
          ),
        );
      }
      return _Shelf(
        title,
        snap.data!,
        onBack: _reloadLists,
        onSeeAll: seeAll == null ? null : () => openSearch(context, seeAll),
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

Future<void> openSearch(BuildContext context, SearchFilters filters) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(filters: filters)),
    );

/// Airing now: still releasing, or from the current season.
bool _airingNow(dynamic media) {
  final (season, year) = AniList.currentSeason;
  return media['status'] == 'RELEASING' ||
      (media['season'] == season && media['seasonYear'] == year);
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        child,
      ],
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.viewer, required this.onSettings});

  final Future<Map<String, dynamic>?> viewer;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
      child: Row(
        children: [
          Text(
            'AniView',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: .5,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SearchScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Downloads',
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
          ),
          // Account lives in Settings, so your avatar is the settings button once signed in.
          FutureBuilder(
            future: viewer,
            builder: (context, snap) {
              final avatar = snap.data?['avatar']?['large'] as String?;
              return IconButton(
                tooltip: 'Settings',
                onPressed: onSettings,
                icon: avatar == null
                    ? const Icon(Icons.settings_outlined)
                    : CircleAvatar(
                        radius: 15,
                        backgroundImage: NetworkImage(avatar),
                      ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _Hero extends StatefulWidget {
  const _Hero({
    required this.items,
    required this.loading,
    required this.onRetry,
    this.error,
  });

  final List items;
  final bool loading;
  final VoidCallback onRetry;
  final Object? error;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  final controller = PageController();
  int page = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .52,
      child: Stack(
        children: [
          if (widget.loading) ...[
            const Positioned.fill(child: Skeleton(radius: 0)),
            const Positioned(
              left: 20,
              bottom: 40,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Skeleton(width: 130, height: 12, radius: 6),
                  SizedBox(height: 12),
                  Skeleton(width: 240, height: 30, radius: 8),
                  SizedBox(height: 18),
                  Skeleton(width: 140, height: 44, radius: 22),
                ],
              ),
            ),
          ] else if (widget.error != null)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.only(top: 48),
                child: ErrorState(widget.error!, onRetry: widget.onRetry),
              ),
            )
          else if (widget.items.isEmpty)
            const Positioned.fill(
              child: EmptyState(
                icon: Icons.local_fire_department_outlined,
                title: 'Nothing trending right now',
              ),
            )
          else
            PageView.builder(
              controller: controller,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (context, i) => _HeroPage(widget.items[i]),
            ),
          if (!widget.loading && widget.items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == page ? 22 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == page ? primary : Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroPage extends StatelessWidget {
  const _HeroPage(this.media);

  final Map media;

  @override
  Widget build(BuildContext context) {
    final genres = (media['genres'] as List).take(3).join('  •  ');
    return GestureDetector(
      onTap: () => openDetails(context, media),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Img(
            media['coverImage']['extraLarge'],
            color: media['coverImage']['color'],
            alignment: Alignment.topCenter,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xAA000000),
                  Colors.transparent,
                  Color(0xDD0A0A0F),
                  background,
                ],
                stops: [0, .3, .78, 1],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 40,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  genres.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  titleOf(media),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => openDetails(context, media),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Watch now'),
                    ),
                    const SizedBox(width: 12),
                    if (media['averageScore'] != null)
                      _Score(media['averageScore']),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TvRail extends StatelessWidget {
  const _TvRail({
    required this.homeFocus,
    required this.onSearch,
    required this.onDownloads,
    required this.onSettings,
  });

  final FocusNode homeFocus;
  final VoidCallback onSearch, onDownloads, onSettings;

  @override
  Widget build(BuildContext context) => Container(
    width: 76,
    color: Colors.black.withValues(alpha: .35),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (icon, label, onTap) in [
          (Icons.home_rounded, 'Home', null),
          (Icons.search_rounded, 'Search', onSearch),
          (Icons.download_for_offline_outlined, 'Downloads', onDownloads),
          (Icons.settings_outlined, 'Settings', onSettings),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: IconButton(
              tooltip: label,
              iconSize: 28,
              autofocus: onTap == null,
              focusNode: onTap == null ? homeFocus : null,
              isSelected: onTap == null,
              color: Colors.white60,
              selectedIcon: Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
              ),
              icon: Icon(icon),
              onPressed: onTap ?? () {},
            ),
          ),
      ],
    ),
  );
}

/// The focused show on the TV home: its artwork on the right, fading into its details on the left.
class _Billboard extends StatelessWidget {
  const _Billboard(this.media, {super.key});

  final Map media;

  @override
  Widget build(BuildContext context) {
    final description = (media['description'] as String? ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    final meta = [
      media['format'],
      media['seasonYear'],
      if (media['episodes'] != null) '${media['episodes']} eps',
      ...(media['genres'] as List).take(3),
    ].whereType<Object>().join('  ·  ');
    return Stack(
      fit: StackFit.expand,
      children: [
        FractionallySizedBox(
          alignment: Alignment.centerRight,
          widthFactor: .65,
          child: _Img(
            media['bannerImage'] ?? media['coverImage']['extraLarge'],
            color: media['coverImage']['color'],
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [background, background, Colors.transparent],
              stops: [0, .35, .75],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, background],
              stops: [.6, 1],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 0, 12),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: .48,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  titleOf(media),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (media['averageScore'] != null) ...[
                      _Score(media['averageScore'], compact: true),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Material(
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primary.withValues(alpha: .28),
                  Colors.white.withValues(alpha: .03),
                ],
              ),
              border: Border.all(color: Colors.white10),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              children: [
                Icon(Icons.sync_rounded, size: 28),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sign in with AniList',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Track what you watch automatically',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf(
    this.title,
    this.items, {
    this.onBack,
    this.onSeeAll,
    this.subtitles,
    this.onLongPress,
  });

  final String title;
  final List items;
  final VoidCallback? onBack, onSeeAll;

  /// Per item, replacing the poster's own progress line.
  final List<String>? subtitles;
  final ValueChanged<int>? onLongPress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(20, onSeeAll == null ? 28 : 16, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (onSeeAll != null)
              TextButton(onPressed: onSeeAll, child: const Text('See all')),
          ],
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        // Smaller on TV, so the billboard and more than one row fit on screen.
        height: isTv ? 222 : 272,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, i) => SizedBox(
            width: isTv ? 104 : 136,
            child: PosterCard(
              items[i],
              onBack: onBack,
              subtitle: subtitles?[i],
              onLongPress: onLongPress == null ? null : () => onLongPress!(i),
            ),
          ),
        ),
      ),
    ],
  );
}

/// "EP 12 · 2d" until the next episode of a releasing show airs; null when AniList gave no time or it has aired.
String? airingLabel(Map media) {
  final next = media['nextAiringEpisode'] as Map?;
  final at = next?['airingAt'] as int?;
  if (at == null) return null;
  final left = DateTime.fromMillisecondsSinceEpoch(at * 1000)
      .difference(DateTime.now());
  if (left.isNegative) return null;
  final when = left.inDays > 0
      ? '${left.inDays}d'
      : left.inHours > 0
      ? '${left.inHours}h'
      : '${left.inMinutes}m';
  return 'EP ${next!['episode']} · $when';
}

/// Poster artwork that flies between a card and the details cover. It flies as the card's already-decoded image
/// (the cover's may still be loading), clipped to the shared corner radius the whole way.
class _PosterHero extends StatelessWidget {
  const _PosterHero({required this.tag, required this.child});

  final Object? tag;
  final Widget child;

  @override
  Widget build(BuildContext context) => tag == null
      ? child
      : Hero(
          tag: tag!,
          flightShuttleBuilder: (_, _, direction, from, to) => ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child:
                ((direction == HeroFlightDirection.push ? from : to).widget
                        as Hero)
                    .child,
          ),
          child: child,
        );
}

Timer? _billboardDelay;

/// TV: keeps a focused poster a couple of posters in from the shelf's edge, so what's next stays in view,
/// and shows it on the billboard once focus rests there, not for every poster the D-pad passes.
void _focusPoster(BuildContext context, Map media) {
  final shelf = Scrollable.maybeOf(context, axis: Axis.horizontal)?.position;
  final card = context.findRenderObject();
  if (shelf != null && card != null) {
    shelf.ensureVisible(
      card,
      alignment: .3,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }
  _billboardDelay?.cancel();
  _billboardDelay = Timer(
    const Duration(milliseconds: 220),
    () => focusedMedia.value = media,
  );
}

class PosterCard extends StatelessWidget {
  const PosterCard(
    this.media, {
    super.key,
    this.onBack,
    this.subtitle,
    this.onLongPress,
  });

  final Map media;
  final VoidCallback? onBack, onLongPress;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final progress = media['mediaListEntry']?['progress'] as int?;
    final aired = media['nextAiringEpisode']?['episode'] as int?;
    final total =
        media['episodes'] as int? ?? (aired == null ? null : aired - 1);
    final airing = airingLabel(media);
    final line =
        subtitle ??
        (progress == null
            ? null
            : 'EP $progress${total == null ? '' : ' / $total'}');
    return Semantics(
      button: true,
      label: [titleOf(media), ?line].join(', '),
      excludeSemantics: true,
      child: PressScale(
        builder: (onHighlightChanged) => Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Tagged with this card's element: unique even when a show is in two shelves, and stable across rebuilds.
                        _PosterHero(
                          tag: context,
                          child: LayoutBuilder(
                            builder: (context, box) => _Img(
                              media['coverImage']['extraLarge'],
                              color: media['coverImage']['color'],
                              decodeWidth: box.maxWidth,
                            ),
                          ),
                        ),
                        if (media['averageScore'] != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _Score(media['averageScore'], compact: true),
                          ),
                        if (airing != null)
                          Positioned(
                            left: 8,
                            bottom: 10,
                            child: _AiringBadge(airing),
                          ),
                        if (progress != null && total != null && total > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: (progress / total)
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                              minHeight: 4,
                              backgroundColor: Colors.black54,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  titleOf(media),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                if (line != null)
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
              ],
            ),
            // On top, so the ripple shows over the artwork.
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => openDetails(
                    context,
                    media,
                    onBack: onBack,
                    heroTag: context,
                  ),
                  onLongPress: onLongPress,
                  onHighlightChanged: onHighlightChanged,
                  onFocusChange: (focused) {
                    if (focused) _focusPoster(context, media);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiringBadge extends StatelessWidget {
  const _AiringBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule_rounded,
          size: 11,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

// ───────────────────────────── Search ─────────────────────────────

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.filters, this.voice = false});

  /// Opens browsing these right away ("See all", a genre chip) instead of an empty search.
  final SearchFilters? filters;

  /// Opens listening for a spoken query (the TV remote's search key).
  final bool voice;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final controller = TextEditingController();
  String query = '';
  late SearchFilters filters = widget.filters ?? const SearchFilters();
  List items = [];
  Object? error;
  bool searched = false, loading = false, hasNext = false;
  int page = 0, _generation = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    Analytics.screen('/search', title: 'Search');
    if (widget.filters != null) _search('', now: true);
    if (widget.voice) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
    }
  }

  Future<void> _listen() async {
    try {
      final spoken = await recognizeSpeech();
      if (spoken == null || spoken.isEmpty || !mounted) return;
      controller.text = spoken;
      _search(spoken, now: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Keeps a query that led somewhere (a show was opened from its results).
  void _remember() {
    if (query.isEmpty) return;
    Settings.recentSearches = [
      query,
      ...Settings.recentSearches.where(
        (q) => q.toLowerCase() != query.toLowerCase(),
      ),
    ];
  }

  void _setFilters(SearchFilters picked) {
    setState(() => filters = picked);
    Analytics.event('search_filter', {
      'filters': picked.count,
      'sort': picked.sort,
    });
    _search(controller.text, now: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    controller.dispose();
    super.dispose();
  }

  /// Searches [text], or browses by the filters alone when it's empty.
  void _search(String text, {bool now = false}) {
    _debounce?.cancel();
    final q = text.trim();
    final browsing = filters.count > 0 || filters.sort != null;
    if (q.length == 1 || (q.isEmpty && !browsing)) return;
    _debounce = Timer(
      now ? Duration.zero : const Duration(milliseconds: 450),
      () {
        if (mounted) {
          setState(() {
            query = q;
            searched = true;
          });
          // Never the text itself.
          Analytics.event('search', {
            'has_text': q.isNotEmpty,
            'filters': filters.count,
          });
          _load(fresh: true);
        }
      },
    );
  }

  /// Fetches the first page when [fresh], otherwise appends the next one.
  Future<void> _load({bool fresh = false}) async {
    if (!fresh && (loading || !hasNext)) return;
    final generation = fresh ? ++_generation : _generation;
    final next = fresh ? 1 : page + 1;
    setState(() {
      loading = true;
      error = null;
      if (fresh) items = [];
    });
    try {
      final (found, more) = await Tracker.search(query, filters, page: next);
      // A newer search replaced this one.
      if (!mounted || generation != _generation) return;
      setState(() {
        items = [...items, ...found];
        page = next;
        hasNext = more;
        loading = false;
      });
      // A short page (MyAnimeList results after filtering) may not fill the screen enough to scroll for more.
      if (more && found.length < 20) _load();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<SearchFilters>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _sheet,
      builder: (_) => _FilterSheet(filters),
    );
    if (picked == null || !mounted) return;
    _setFilters(picked);
  }

  /// One removable chip per active filter.
  List<(String, SearchFilters)> get _activeFilters {
    final f = filters;
    SearchFilters copy({
      bool sort = true,
      bool season = true,
      bool year = true,
      bool format = true,
      bool status = true,
      Set<String>? genres,
    }) => SearchFilters(
      sort: sort ? f.sort : null,
      season: season ? f.season : null,
      year: year ? f.year : null,
      format: format ? f.format : null,
      status: status ? f.status : null,
      genres: genres ?? f.genres,
    );
    return [
      if (f.sort != null)
        (_FilterSheetState._sorts[f.sort]!, copy(sort: false)),
      if (f.season != null)
        (_FilterSheetState._seasons[f.season]!, copy(season: false)),
      if (f.year != null) ('${f.year}', copy(year: false)),
      if (f.format != null)
        (_FilterSheetState._formats[f.format]!, copy(format: false)),
      if (f.status != null)
        (_FilterSheetState._statuses[f.status]!, copy(status: false)),
      for (final g in f.genres) (g, copy(genres: {...f.genres}..remove(g))),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    appBar: AppBar(
      titleSpacing: 0,
      bottom: _activeFilters.isEmpty
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  children: [
                    for (final (label, without) in _activeFilters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          label: Text(label),
                          visualDensity: VisualDensity.compact,
                          onPressed: _openFilters,
                          onDeleted: () => _setFilters(without),
                          deleteButtonTooltipMessage: 'Remove $label',
                        ),
                      ),
                  ],
                ),
              ),
            ),
      title: TextField(
        controller: controller,
        autofocus: widget.filters == null && !widget.voice,
        textInputAction: TextInputAction.search,
        onChanged: _search,
        onSubmitted: (text) => _search(text, now: true),
        decoration: _searchDecoration('Search anime'),
      ),
      actions: [
        // Phones already have a mic on the keyboard; a remote's on-screen keyboard is slow going.
        if (isTv)
          IconButton(
            tooltip: 'Search by voice',
            onPressed: _listen,
            icon: const Icon(Icons.mic_rounded),
          ),
        IconButton(
          tooltip: 'Filters',
          onPressed: _openFilters,
          icon: Badge(
            isLabelVisible: filters.count > 0,
            label: Text('${filters.count}'),
            child: const Icon(Icons.tune_rounded),
          ),
        ),
      ],
    ),
    body: _results(),
  );

  Widget _results() {
    if (!searched) {
      final recent = Settings.recentSearches;
      if (recent.isEmpty) {
        return const EmptyState(
          icon: Icons.travel_explore_rounded,
          title: 'Find your next show',
          message: 'Search by English or Japanese title, or browse by season, genre and more with filters',
        );
      }
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Recent searches',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => Settings.recentSearches = const []),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          for (final q in recent)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.history_rounded),
              title: Text(q),
              onTap: () {
                controller.text = q;
                _search(q, now: true);
              },
            ),
        ],
      );
    }
    if (items.isEmpty && loading) {
      return GridView.builder(
        padding: const EdgeInsets.all(20),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: _posterGrid,
        itemCount: 9,
        itemBuilder: (_, _) => const PosterSkeleton(),
      );
    }
    if (items.isEmpty && error != null) {
      return ErrorState(error!, onRetry: () => _load(fresh: true));
    }
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: query.isEmpty
            ? 'No shows match these filters'
            : 'No results for “$query”',
        message: filters.count > 0
            ? 'Try removing a filter'
            : 'Check the spelling or try the other title',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 800 && error == null) _load();
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            sliver: SliverGrid.builder(
              gridDelegate: _posterGrid,
              itemCount: items.length,
              itemBuilder: (context, i) =>
                  PosterCard(items[i], onBack: _remember),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: error != null
                  ? ErrorState(error!, compact: true, onRetry: _load)
                  : loading
                  ? const Center(child: CircularProgressIndicator())
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet(this.filters);

  final SearchFilters filters;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? sort = widget.filters.sort,
      season = widget.filters.season,
      format = widget.filters.format,
      status = widget.filters.status;
  late int? year = widget.filters.year;
  late final genres = {...widget.filters.genres};

  static const _sorts = <String?, String>{
    null: 'Best match',
    'POPULARITY_DESC': 'Popular',
    'TRENDING_DESC': 'Trending',
    'SCORE_DESC': 'Top rated',
    'START_DATE_DESC': 'Newest',
  };
  static const _seasons = <String?, String>{
    null: 'Any',
    'WINTER': 'Winter',
    'SPRING': 'Spring',
    'SUMMER': 'Summer',
    'FALL': 'Fall',
  };
  static const _formats = <String?, String>{
    null: 'Any',
    'TV': 'TV',
    'MOVIE': 'Movie',
    'OVA': 'OVA',
    'ONA': 'ONA',
    'SPECIAL': 'Special',
    'TV_SHORT': 'TV short',
  };
  static const _statuses = <String?, String>{
    null: 'Any',
    'RELEASING': 'Airing',
    'FINISHED': 'Finished',
    'NOT_YET_RELEASED': 'Upcoming',
  };
  static const _genres = [
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Ecchi',
    'Fantasy',
    'Horror',
    'Mahou Shoujo',
    'Mecha',
    'Music',
    'Mystery',
    'Psychological',
    'Romance',
    'Sci-Fi',
    'Slice of Life',
    'Sports',
    'Supernatural',
    'Thriller',
  ];

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );

  Widget _choices(
    Map<String?, String> options,
    String? selected,
    ValueChanged<String?> pick,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final MapEntry(:key, :value) in options.entries)
        ChoiceChip(
          label: Text(value),
          selected: key == selected,
          onSelected: (_) => setState(() => pick(key)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Filters',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          _label('Sort by'),
          _choices(_sorts, sort, (v) => sort = v),
          _label('Season'),
          _choices(_seasons, season, (v) => season = v),
          _label('Year'),
          DropdownButton<int?>(
            value: year,
            dropdownColor: _sheet,
            menuMaxHeight: 320,
            items: [
              const DropdownMenuItem(child: Text('Any')),
              for (var y = DateTime.now().year + 1; y >= 1970; y--)
                DropdownMenuItem(value: y, child: Text('$y')),
            ],
            onChanged: (v) => setState(() => year = v),
          ),
          _label('Format'),
          _choices(_formats, format, (v) => format = v),
          _label('Status'),
          _choices(_statuses, status, (v) => status = v),
          _label('Genres'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final genre in _genres)
                FilterChip(
                  label: Text(genre),
                  selected: genres.contains(genre),
                  onSelected: (on) => setState(
                    () => on ? genres.add(genre) : genres.remove(genre),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, const SearchFilters()),
                child: const Text('Reset'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  SearchFilters(
                    sort: sort,
                    season: season,
                    year: year,
                    format: format,
                    status: status,
                    genres: genres,
                  ),
                ),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

InputDecoration _searchDecoration(String hint, {Widget? suffix}) =>
    InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: Colors.white.withValues(alpha: .07),
      prefixIcon: const Icon(Icons.search_rounded),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
    );

// ───────────────────────────── Details ─────────────────────────────

class DetailsScreen extends StatefulWidget {
  const DetailsScreen(this.media, {super.key, this.heroTag});

  final Map media;

  /// The tapped poster's [Hero] tag, so its artwork flies into the cover.
  final Object? heroTag;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  List<Source>? sources;
  Object? sitesError;
  Source? source;
  Future<List<Episode>>? episodes;

  /// MAL entries arrive without an AniList id, which history, downloads and sources are keyed by.
  late final Future<void> _ids = Tracker.resolveIds(widget.media);
  late Future<Map<String, dynamic>?> record = _ids.then(
    (_) => WatchHistory.of(widget.media),
  );
  late final relations = _ids.then((_) => Tracker.relations(widget.media));
  late final cachedSeason = _ids.then(
    (_) => Downloads.instance.season(widget.media),
  );
  bool dub = Settings.preferDub,
      expanded = false,
      newestFirst = Settings.newestFirst;

  /// Chosen page of episodes; null follows the page holding the next unwatched one.
  int? page;
  static const _pageSize = 50;

  Map get media => widget.media;

  @override
  void initState() {
    super.initState();
    Analytics.screen('/details', title: titleOf(media));
    _loadSites();
  }

  /// Long-press on an episode: watched state and its download.
  Future<void> _episodeActions(
    Episode episode, {
    required bool watched,
    required Source? site,
    required List<Episode> season,
  }) async {
    HapticFeedback.mediumImpact();
    if (!Settings.episodeTipSeen) {
      setState(() => Settings.episodeTipSeen = true);
    }
    final download = Downloads.instance.entry(media, episode.number, dub);
    final action = await showModalBottomSheet<VoidCallback>(
      context: context,
      showDragHandle: true,
      backgroundColor: _sheet,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Episode ${epNumber(episode.number)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: Icon(
                watched ? Icons.remove_done_rounded : Icons.done_all_rounded,
              ),
              title: Text(
                watched ? 'Mark as unwatched' : 'Mark watched up to here',
              ),
              onTap: () => Navigator.pop(
                context,
                () => _markWatched(
                  watched ? episode.number.ceil() - 1 : episode.number.toInt(),
                ),
              ),
            ),
            if (site != null && download == null)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.download_rounded),
                title: Text('Download ${dub ? 'dub' : 'sub'}'),
                onTap: () => Navigator.pop(
                  context,
                  () => Downloads.instance.enqueue(
                    media,
                    site.name,
                    [episode],
                    dub: dub,
                    season: season,
                  ),
                ),
              ),
            if (download?.status == DownloadStatus.done)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete download'),
                onTap: () => Navigator.pop(
                  context,
                  () => _confirmDelete(this.context, download!),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    action?.call();
  }

  Future<void> _loadSites() async {
    try {
      await _ids;
      final found = await sites;
      if (!mounted) return;
      setState(() => sources = found);
      final preferred =
          found.where((s) => s.name == Settings.preferredSource).firstOrNull ??
          found.firstOrNull;
      if (preferred != null) _select(preferred);
    } catch (e) {
      sites = topSources()..ignore(); // fresh attempt for the retry button
      if (mounted) setState(() => sitesError = e);
    }
  }

  // Episodes load only for the chosen site, so a Cloudflare prompt appears only when that site needs one.
  void _select(Source s) => setState(() {
    source = s;
    page = null;
    episodes = withCloudflare(context, () => loadEpisodes(s, media)).then((
      list,
    ) {
      Downloads.instance.saveSeason(
        media,
        list,
      ); // keeps the offline copy current
      return list;
    });
  });

  /// Sets tracked progress to [progress] episodes; queued for later when offline and moving forward.
  Future<void> _markWatched(int progress) async {
    if (!Tracker.signedIn) {
      return showError(context, 'Sign in with AniList to track episodes');
    }
    final synced = await Tracker.save(media, progress);
    if (!mounted) return;
    setState(() {});
    showSuccess(
      context,
      !synced
          ? 'Saved · syncs next time you open the app'
          : progress == 0
          ? 'Marked as unwatched'
          : 'Watched up to Episode $progress',
    );
  }

  Future<void> _downloadSeason(
    Source site,
    List<Episode> list,
    int progress,
  ) async {
    final picked = await showDialog<List<Episode>>(
      context: context,
      builder: (_) => _DownloadRangeDialog(list, progress: progress, dub: dub),
    );
    if (picked == null || !mounted) return;
    final count = picked.where((e) {
      final d = Downloads.instance.entry(media, e.number, dub);
      return d == null || d.status == DownloadStatus.failed;
    }).length;
    Downloads.instance.enqueue(
      media,
      site.name,
      picked,
      dub: dub,
      season: list,
    );
    Analytics.event('download_queue', {
      'media_id': media['id'],
      'episodes': count,
      'dub': dub,
    });
    showSuccess(
      context,
      count == 0
          ? 'Every episode is already downloaded or queued'
          : 'Downloading $count ${dub ? 'dub' : 'sub'} episodes',
    );
  }

  Future<void> _editEntry() async {
    final entry = media['mediaListEntry'] as Map?;
    final result =
        await showModalBottomSheet<
          ({String status, int progress, bool remove})
        >(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          backgroundColor: _sheet,
          builder: (_) => _EntrySheet(
            status: entry?['status'],
            progress: entry?['progress'] as int? ?? 0,
            total: media['episodes'] as int?,
            inList: entry != null,
          ),
        );
    if (result == null || !mounted) return;
    try {
      if (result.remove) {
        await Tracker.removeFromList(media);
        media['mediaListEntry'] = null;
        if (mounted) showSuccess(context, 'Removed from your list');
      } else {
        final synced = await Tracker.save(
          media,
          result.progress,
          status: result.status,
        );
        if (mounted) {
          showSuccess(
            context,
            synced
                ? 'Saved as ${_ProgressCard.labels[result.status]} · ${result.progress} watched'
                : 'Saved · syncs next time you open the app',
          );
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _fixMatch() async {
    final current = source;
    if (current == null) return;
    final picked = await showModalBottomSheet<SearchResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: _sheet,
      builder: (_) => _MatchSheet(source: current, query: titleOf(media)),
    );
    if (picked == null || !mounted) return;
    await setMatch(current, media, picked.id);
    if (!mounted) return;
    _select(current);
    showSuccess(context, 'Using “${picked.title}” on ${current.name}');
  }

  @override
  Widget build(BuildContext context) {
    final accent =
        _hex(media['coverImage']['color']) ??
        Theme.of(context).colorScheme.primary;
    final entry = media['mediaListEntry'] as Map?;
    final progress = entry?['progress'] as int? ?? 0;
    final total = media['episodes'] as int?;
    final meta = [
      media['format'],
      media['seasonYear'],
      if (total != null) '$total eps',
      (media['status'] as String?)?.replaceAll('_', ' '),
    ].whereType<Object>().join('  ·  ');
    final airing = airingLabel(media);
    final description = (media['description'] as String? ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();

    final info = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 110,
            height: 160,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: .4),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: _PosterHero(
              tag: widget.heroTag,
              child: _Img(
                media['coverImage']['extraLarge'],
                color: media['coverImage']['color'],
                // A shelf poster's size, so the one that just flew in is already decoded.
                decodeWidth: 136,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleOf(media),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  meta,
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1,
                    color: Colors.white70,
                  ),
                ),
                if (airing != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _AiringBadge('Next: $airing'),
                  ),
                const SizedBox(height: 10),
                if (media['averageScore'] != null)
                  _Score(media['averageScore']),
              ],
            ),
          ),
        ],
      ),
      if (Tracker.signedIn) ...[
        const SizedBox(height: 20),
        _ProgressCard(
          progress: progress,
          total: total,
          status: entry?['status'],
          accent: accent,
          onTap: _editEntry,
        ),
      ],
      if ((media['genres'] as List).isNotEmpty) ...[
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final genre in media['genres'])
              ActionChip(
                label: Text('$genre'),
                tooltip: 'Browse $genre',
                visualDensity: VisualDensity.compact,
                side: BorderSide.none,
                backgroundColor: Colors.white.withValues(alpha: .06),
                onPressed: () =>
                    openSearch(context, SearchFilters(genres: {'$genre'})),
              ),
          ],
        ),
      ],
      if (description.isNotEmpty) ...[
        const SizedBox(height: 16),
        // An InkWell so the D-pad can reach it on TV to read the rest.
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => expanded = !expanded),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: Text(
              description,
              maxLines: expanded ? null : (isTv ? 6 : 4),
              overflow: expanded ? null : TextOverflow.fade,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
          ),
        ),
      ],
      FutureBuilder(
        future: relations,
        builder: (context, snap) => Column(
          children: [
            for (final (type, related) in snap.data ?? const <(String, Map)>[])
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _RelationTile(type, related),
              ),
          ],
        ),
      ),
    ];
    final episodesHeader = <Widget>[
      const SizedBox(height: 28),
      Row(
        children: [
          const Text(
            'Episodes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('SUB')),
              ButtonSegment(value: true, label: Text('DUB')),
            ],
            selected: {dub},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() => dub = s.first),
          ),
          FutureBuilder(
            future: episodes,
            builder: (context, snap) {
              final list = snap.data, site = source;
              if (list == null || list.isEmpty || site == null) {
                return const SizedBox.shrink();
              }
              return PopupMenuButton<VoidCallback>(
                tooltip: 'Season actions',
                icon: const Icon(Icons.more_vert_rounded),
                color: _sheet,
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: () => _downloadSeason(site, list, progress),
                    child: const ListTile(
                      leading: Icon(Icons.download_rounded),
                      title: Text('Download episodes…'),
                    ),
                  ),
                  if (Tracker.signedIn)
                    PopupMenuItem(
                      value: () => _markWatched(
                        list.fold(
                          0,
                          (n, e) => e.number > n ? e.number.toInt() : n,
                        ),
                      ),
                      child: const ListTile(
                        leading: Icon(Icons.done_all_rounded),
                        title: Text('Mark season watched'),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      const SizedBox(height: 12),
      _sourcePicker(),
      if (source != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _fixMatch,
            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
            label: const Text('Wrong show? Pick the right one'),
          ),
        ),
    ];
    if (isTv) return _tvLayout(progress, info, episodesHeader);
    return Scaffold(
      backgroundColor: background,
      floatingActionButton: _continueButton(progress),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            stretch: true,
            expandedHeight: 280,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _Img(
                    media['bannerImage'] ?? media['coverImage']['extraLarge'],
                    color: media['coverImage']['color'],
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x88000000),
                          Colors.transparent,
                          background,
                        ],
                        stops: [0, .4, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.list(children: [...info, ...episodesHeader]),
          ),
          _episodeList(progress),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  /// TV: the show's art behind two panes, its details (with the play button up top) on the left and the
  /// episodes on the right, each scrolling on its own as the D-pad moves.
  Widget _tvLayout(
    int progress,
    List<Widget> info,
    List<Widget> episodesHeader,
  ) => Scaffold(
    backgroundColor: background,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: .35,
          child: _Img(
            media['bannerImage'] ?? media['coverImage']['extraLarge'],
            color: media['coverImage']['color'],
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [background, Color(0xCC0A0A0F), Color(0x660A0A0F)],
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: MediaQuery.sizeOf(context).width * .42,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(32, 32, 16, 32),
                children: [
                  ...info.take(1), // poster and title
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _continueButton(progress),
                  ),
                  ...info.skip(1),
                ],
              ),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 32, 0),
                    sliver: SliverList.list(children: episodesHeader),
                  ),
                  _episodeList(progress),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );

  /// Resume the saved spot for this show, else continue after the tracked progress on the selected source.
  Widget _continueButton(int progress) => FutureBuilder(
    future: record,
    builder: (context, saved) {
      final r = saved.data;
      if (r != null) {
        final at = Duration(milliseconds: r['position'] as int? ?? 0);
        final resumes = Settings.resume && at > Duration.zero;
        return ContinueFab(
          title:
              '${resumes ? 'Resume' : 'Continue'} EP ${epNumber(r['episode'])}',
          subtitle:
              '${r['source']}${resumes ? ' · ${formatDuration(at)}' : ''}',
          onPressed: () async {
            final loaded = r['source'] == source?.name ? await episodes : null;
            if (!context.mounted) return;
            await resumeWatching(context, r, loaded: loaded);
            if (mounted) setState(() => record = WatchHistory.of(media));
          },
        );
      }
      return FutureBuilder(
        future: episodes,
        builder: (context, snap) {
          final list = snap.data;
          final upNext = list == null
              ? null
              : EpisodePlan(list, progress: progress).upNext;
          if (list == null || upNext == null) return const SizedBox.shrink();
          final next = list.indexOf(upNext);
          final current = source!;
          return ContinueFab(
            title: progress == 0
                ? 'Start watching'
                : 'Continue EP ${epNumber(list[next].number)}',
            subtitle: current.name,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(
                    media: media,
                    source: current,
                    episodes: list,
                    index: next,
                    dub: dub,
                  ),
                ),
              );
              if (mounted) setState(() => record = WatchHistory.of(media));
            },
          );
        },
      );
    },
  );

  Widget _sourcePicker() {
    if (sitesError != null) {
      return ErrorState(
        sitesError!,
        compact: true,
        onRetry: () {
          setState(() => sitesError = null);
          _loadSites();
        },
      );
    }
    if (sources == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Skeleton(width: 160, height: 44, radius: 22),
      );
    }
    if (sources!.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: Icons.dns_outlined,
        title: 'No supported sites',
        message: "None of everythingmoe's top sites are supported yet.",
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(24),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<Source>(
            value: source,
            icon: const Icon(Icons.arrow_drop_down_rounded),
            dropdownColor: _sheet,
            borderRadius: BorderRadius.circular(12),
            style: const TextStyle(fontWeight: FontWeight.w600),
            items: [
              for (final (i, s) in sources!.indexed)
                DropdownMenuItem(
                  value: s,
                  child: Text('#${i + 1}  ${s.label}'),
                ),
            ],
            onChanged: (s) {
              if (s != null && s != source) _select(s);
            },
          ),
        ),
      ),
    );
  }

  /// [site] is null offline, when only downloaded episodes play. Long-press toggles watched.
  /// Shown [_pageSize] at a time, newest first by default; the player always gets them in order.
  Widget _episodeSliver(List<Episode> list, int progress, Source? site) {
    final playable = site != null
        ? list
        : [
            for (final e in list)
              if (Downloads.instance.find(media, e.number) != null) e,
          ];
    return FutureBuilder(
      future: record,
      builder: (context, saved) => _episodePage(
        list,
        playable,
        site,
        EpisodePlan(
          list,
          progress: progress,
          record: saved.data,
          newestFirst: newestFirst,
          page: page,
          pageSize: _pageSize,
        ),
      ),
    );
  }

  Widget _episodePage(
    List<Episode> list,
    List<Episode> playable,
    Source? site,
    EpisodePlan plan,
  ) {
    final pages = plan.pages;
    final current = plan.page;
    final shown = plan.shown;
    return SliverMainAxisGroup(
      slivers: [
        if (!Settings.episodeTipSeen && list.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.touch_app_outlined,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isTv
                          ? 'Hold OK on an episode to mark it watched or manage its download'
                          : 'Long-press an episode to mark it watched or manage its download',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Got it',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () =>
                        setState(() => Settings.episodeTipSeen = true),
                  ),
                ],
              ),
            ),
          ),
        if (list.length > 1)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 0, 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() {
                      Settings.newestFirst = newestFirst = !newestFirst;
                      page = null;
                    }),
                    icon: const Icon(Icons.swap_vert_rounded, size: 18),
                    label: Text(newestFirst ? 'Newest first' : 'Oldest first'),
                  ),
                  if (pages.length > 1)
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.only(right: 20),
                          itemCount: pages.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) => ChoiceChip(
                            label: Text(
                              '${epNumber(pages[i].first.number)}–${epNumber(pages[i].last.number)}',
                            ),
                            selected: i == current,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onSelected: (_) => setState(() => page = i),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final episode = shown[i];
            final watched = plan.watched(episode);
            final saved = site != null || playable.contains(episode);
            return _EpisodeTile(
              episode,
              watched: watched,
              upNext: episode == plan.upNext,
              watchedPart: plan.resumedPart(episode),
              onLongPress: () => _episodeActions(
                episode,
                watched: watched,
                site: site,
                season: list,
              ),
              trailing: site == null
                  ? saved
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(
                              Icons.download_done_rounded,
                              color: Colors.white54,
                            ),
                          )
                        : null
                  : _DownloadButton(
                      media: media,
                      source: site,
                      episode: episode,
                      season: list,
                      dub: dub,
                    ),
              onTap: () async {
                if (!saved) {
                  showError(
                    context,
                    "Episode ${epNumber(episode.number)} isn't downloaded",
                  );
                  return;
                }
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerScreen(
                      media: media,
                      source: site,
                      sourceName:
                          site?.name ??
                          Downloads.instance
                              .forMedia(media)
                              .firstOrNull
                              ?.source,
                      episodes: playable,
                      index: playable.indexOf(episode),
                      dub: dub,
                    ),
                  ),
                );
                if (mounted) {
                  setState(
                    () => record = WatchHistory.of(media),
                  ); // progress and resume point changed
                }
              },
            );
          },
        ),
      ],
    );
  }

  /// Downloaded episodes, shown when the site can't be reached.
  Widget? _offlineList(int progress) {
    final downloaded = [
      for (final d in Downloads.instance.forMedia(media)) d.episode,
    ];
    if (downloaded.isEmpty) return null;
    return SliverMainAxisGroup(
      slivers: [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 18, color: Colors.white54),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Can't reach the site, only downloaded episodes play",
                    style: TextStyle(fontSize: 13, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),
        ),
        FutureBuilder(
          future: cachedSeason,
          builder: (context, snap) =>
              _episodeSliver(snap.data ?? downloaded, progress, null),
        ),
      ],
    );
  }

  Widget _episodeList(int progress) {
    final current = source;
    if (episodes == null || current == null) {
      return (sitesError != null ? _offlineList(progress) : null) ??
          const SliverToBoxAdapter();
    }
    return FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SliverList.builder(
            itemCount: 6,
            itemBuilder: (_, _) => const EpisodeSkeleton(),
          );
        }
        if (snap.hasError) {
          return _offlineList(progress) ??
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ErrorState(
                    snap.error!,
                    compact: true,
                    onRetry: () => _select(current),
                  ),
                ),
              );
        }
        final list = snap.data!;
        if (list.isEmpty) {
          return SliverToBoxAdapter(
            child: EmptyState(
              compact: true,
              icon: Icons.search_off_rounded,
              title: 'Not found on ${current.name}',
              message: 'The site may list it under another name. Pick it manually or try another source.',
              action: FilledButton.tonalIcon(
                onPressed: _fixMatch,
                icon: const Icon(Icons.manage_search_rounded),
                label: const Text('Find it manually'),
              ),
            ),
          );
        }
        return _episodeSliver(list, progress, current);
      },
    );
  }
}

/// Search the selected site and pick the right show when the automatic match is wrong or missing.
class _MatchSheet extends StatefulWidget {
  const _MatchSheet({required this.source, required this.query});

  final Source source;
  final String query;

  @override
  State<_MatchSheet> createState() => _MatchSheetState();
}

class _MatchSheetState extends State<_MatchSheet> {
  late final controller = TextEditingController(text: widget.query);
  late Future<List<SearchResult>> results = _run();

  Future<List<SearchResult>> _run() => withCloudflare(
    context,
    () => widget.source.search(controller.text.trim()),
  );

  void _retry() => setState(() => results = _run());

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      minChildSize: .5,
      maxChildSize: .95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pick the show on ${widget.source.name}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your choice is remembered for this show.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _retry(),
                  decoration: _searchDecoration(
                    'Search ${widget.source.name}',
                    suffix: IconButton(
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: _retry,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: results,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return ListView.builder(
                    controller: scroll,
                    itemCount: 6,
                    itemBuilder: (_, _) => const _ResultSkeleton(),
                  );
                }
                if (snap.hasError) {
                  return ListView(
                    controller: scroll,
                    children: [ErrorState(snap.error!, onRetry: _retry)],
                  );
                }
                if (snap.data!.isEmpty) {
                  return ListView(
                    controller: scroll,
                    children: const [
                      EmptyState(
                        compact: true,
                        icon: Icons.search_off_rounded,
                        title: 'No shows found',
                        message: 'Try a shorter or alternative title',
                      ),
                    ],
                  );
                }
                return ListView.builder(
                  controller: scroll,
                  itemCount: snap.data!.length,
                  itemBuilder: (context, i) {
                    final result = snap.data![i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 62,
                          child: _Img(result.image),
                        ),
                      ),
                      title: Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: result.info == null || result.info!.isEmpty
                          ? null
                          : Text(result.info!),
                      onTap: () => Navigator.pop(context, result),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// A prequel or sequel; opens its details.
class _RelationTile extends StatelessWidget {
  const _RelationTile(this.type, this.media);

  final String type;
  final Map media;

  @override
  Widget build(BuildContext context) {
    final prequel = type == 'PREQUEL';
    return Material(
      color: Colors.white.withValues(alpha: .04),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openDetails(context, media),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 40,
                  height: 56,
                  child: _Img(
                    media['coverImage']['extraLarge'],
                    color: media['coverImage']['color'],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prequel ? 'PREQUEL' : 'SEQUEL',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    Text(
                      titleOf(media),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        media['format'],
                        media['seasonYear'],
                      ].whereType<Object>().join('  ·  '),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                prequel ? Icons.skip_previous_rounded : Icons.skip_next_rounded,
                color: Colors.white54,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultSkeleton extends StatelessWidget {
  const _ResultSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(
      children: [
        Skeleton(width: 44, height: 62, radius: 8),
        SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(height: 14, radius: 6),
              SizedBox(height: 8),
              Skeleton(height: 11, width: 120, radius: 6),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.progress,
    required this.total,
    required this.status,
    required this.accent,
    required this.onTap,
  });

  final int progress;
  final int? total;
  final String? status;
  final Color accent;
  final VoidCallback onTap;

  static const labels = {
    'CURRENT': 'Watching',
    'PLANNING': 'Planning',
    'COMPLETED': 'Completed',
    'PAUSED': 'Paused',
    'DROPPED': 'Dropped',
    'REPEATING': 'Rewatching',
  };

  @override
  Widget build(BuildContext context) {
    final total = this.total;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: [
                accent.withValues(alpha: .22),
                Colors.white.withValues(alpha: .03),
              ],
            ),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    status == null
                        ? Icons.bookmark_add_outlined
                        : Icons.bookmark_rounded,
                    size: 18,
                    color: accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    labels[status] ?? 'Add to your list',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '$progress / ${total ?? '?'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.edit_rounded,
                    size: 16,
                    color: Colors.white54,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total == null || total == 0
                      ? 0
                      : (progress / total).clamp(0.0, 1.0).toDouble(),
                  minHeight: 6,
                  color: accent,
                  backgroundColor: Colors.white10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Edits the list entry: status, episodes watched, or removal.
class _EntrySheet extends StatefulWidget {
  const _EntrySheet({
    required this.status,
    required this.progress,
    required this.total,
    required this.inList,
  });

  final String? status;
  final int progress;
  final int? total;
  final bool inList;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late String status = widget.status ?? 'CURRENT';
  late int progress = widget.progress;

  void _setProgress(int value) => setState(() {
    progress = value.clamp(0, widget.total ?? 9999);
    if (progress == widget.total) status = 'COMPLETED';
  });

  void _done({bool remove = false}) => Navigator.pop(context, (
    status: status,
    progress: progress,
    remove: remove,
  ));

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.inList ? 'Update your list' : 'Add to your list',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(:key, :value)
                    in _ProgressCard.labels.entries)
                  ChoiceChip(
                    label: Text(value),
                    selected: status == key,
                    onSelected: (_) => setState(() {
                      status = key;
                      if (key == 'COMPLETED' && total != null) progress = total;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text(
                  'Episodes watched',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton.filledTonal(
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: progress > 0
                      ? () => _setProgress(progress - 1)
                      : null,
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    '$progress${total == null ? '' : ' / $total'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.add_rounded),
                  onPressed: total == null || progress < total
                      ? () => _setProgress(progress + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.inList)
                  TextButton.icon(
                    onPressed: () => _done(remove: true),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFFF8A8E),
                    ),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _done,
                  child: Text(widget.inList ? 'Save' : 'Add to list'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile(
    this.episode, {
    required this.watched,
    required this.onTap,
    this.upNext = false,
    this.watchedPart,
    this.onLongPress,
    this.trailing,
  });

  final Episode episode;
  final bool watched, upNext;

  /// How far into this episode the saved resume point is, 0–1.
  final double? watchedPart;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final thumbnail = episode.thumbnail;
    final title = episode.title;
    final overview = episode.overview;
    final accent = Theme.of(context).colorScheme.primary;
    final part = watchedPart;
    return PressScale(
      builder: (onHighlightChanged) => InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onHighlightChanged: onHighlightChanged,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                width: 128,
                height: 72,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: upNext ? Border.all(color: accent, width: 2) : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.white.withValues(alpha: .05),
                        child: Center(
                          child: Text(
                            epNumber(episode.number),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                      ),
                      if (thumbnail != null)
                        AnimatedOpacity(
                          opacity: watched ? .4 : 1,
                          duration: const Duration(milliseconds: 250),
                          child: _Img(
                            thumbnail,
                            transparent: true,
                            decodeWidth: 128,
                          ),
                        ),
                      if (!watched && thumbnail != null)
                        Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 30,
                            color: Colors.white.withValues(alpha: .9),
                          ),
                        ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeOutBack,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: watched
                              ? const _WatchedBadge()
                              : const SizedBox.shrink(),
                        ),
                      ),
                      if (part != null && !watched)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: part,
                            minHeight: 3,
                            color: accent,
                            backgroundColor: Colors.black54,
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Episode ${epNumber(episode.number)}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: watched ? Colors.white54 : Colors.white,
                            ),
                          ),
                        ),
                        if (upNext) ...[
                          const SizedBox(width: 8),
                          Text(
                            part != null ? 'RESUME' : 'UP NEXT',
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: .8,
                              fontWeight: FontWeight.w800,
                              color: accent,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (title != null)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: watched ? Colors.white38 : Colors.white70,
                        ),
                      ),
                    if (overview != null)
                      Text(
                        overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: watched ? Colors.white30 : Colors.white60,
                          height: 1.3,
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchedBadge extends StatelessWidget {
  const _WatchedBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      shape: BoxShape.circle,
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Icon(
        Icons.check_rounded,
        size: 14,
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    ),
  );
}

/// Shrinks its child a touch while it's held, easing back on release or when a scroll takes the gesture.
/// [builder] gets the callback to hand an InkWell's `onHighlightChanged`.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.builder});

  final Widget Function(ValueChanged<bool> onHighlightChanged) builder;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: pressed && !MediaQuery.disableAnimationsOf(context) ? .97 : 1,
    // Quick to press in, slower to settle back, like something with a little weight.
    duration: Duration(milliseconds: pressed ? 90 : 220),
    curve: pressed ? Curves.easeOut : Curves.easeOutBack,
    child: widget.builder((v) {
      if (v != pressed) setState(() => pressed = v);
    }),
  );
}

// ───────────────────────────── Downloads ─────────────────────────────

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.media,
    required this.source,
    required this.episode,
    required this.season,
    required this.dub,
  });

  final Map media;
  final Source source;
  final Episode episode;
  final List<Episode> season;
  final bool dub;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Downloads.instance,
    builder: (context, _) {
      final d = Downloads.instance.entry(media, episode.number, dub);
      return switch (d?.status) {
        null => IconButton(
          tooltip: 'Download',
          icon: const Icon(Icons.download_rounded, color: Colors.white60),
          onPressed: () => Downloads.instance.enqueue(
            media,
            source.name,
            [episode],
            dub: dub,
            season: season,
          ),
        ),
        DownloadStatus.queued => IconButton(
          tooltip: 'Queued · tap to cancel',
          icon: const Icon(Icons.schedule_rounded, color: Colors.white38),
          onPressed: () => Downloads.instance.remove(d!),
        ),
        DownloadStatus.downloading => IconButton(
          tooltip: '${(d!.progress * 100).round()}% · tap to cancel',
          onPressed: () => Downloads.instance.remove(d),
          icon: SizedBox.square(
            dimension: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: d.progress == 0 ? null : d.progress,
                  strokeWidth: 2.5,
                ),
                const Icon(Icons.stop_rounded, size: 14),
              ],
            ),
          ),
        ),
        DownloadStatus.done => IconButton(
          tooltip: 'Downloaded · tap to delete',
          icon: Icon(
            Icons.download_done_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          onPressed: () => _confirmDelete(context, d!),
        ),
        DownloadStatus.failed => IconButton(
          tooltip: d!.error ?? 'Download failed',
          icon: const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF8A8E),
          ),
          onPressed: () {
            showError(context, 'Retrying · ${d.error ?? 'download failed'}');
            Downloads.instance.retry(d);
          },
        ),
      };
    },
  );
}

/// Picks which episodes to download, so a long show isn't queued whole. Starts at the first unwatched one.
class _DownloadRangeDialog extends StatefulWidget {
  const _DownloadRangeDialog(
    this.episodes, {
    required this.progress,
    required this.dub,
  });

  final List<Episode> episodes;
  final int progress;
  final bool dub;

  @override
  State<_DownloadRangeDialog> createState() => _DownloadRangeDialogState();
}

class _DownloadRangeDialogState extends State<_DownloadRangeDialog> {
  late final sorted = [...widget.episodes]
    ..sort((a, b) => a.number.compareTo(b.number));
  late final from = TextEditingController(
    text: epNumber(
      (sorted.where((e) => e.number > widget.progress).firstOrNull ??
              sorted.first)
          .number,
    ),
  );
  late final to = TextEditingController(text: epNumber(sorted.last.number));

  List<Episode> get picked {
    final a = num.tryParse(from.text), b = num.tryParse(to.text);
    if (a == null || b == null) return const [];
    return [
      for (final e in sorted)
        if (e.number >= a && e.number <= b) e,
    ];
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Widget _field(TextEditingController controller, String label) => Expanded(
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final count = picked.length;
    return AlertDialog(
      title: const Text('Download episodes'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _field(from, 'From'),
              const SizedBox(width: 16),
              _field(to, 'To'),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '$count ${widget.dub ? 'dub' : 'sub'} ${count == 1 ? 'episode' : 'episodes'} · '
            '${epNumber(sorted.first.number)}–${epNumber(sorted.last.number)} available',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: count == 0 ? null : () => Navigator.pop(context, picked),
          child: const Text('Download'),
        ),
      ],
    );
  }
}

Future<void> _confirmDelete(BuildContext context, Download d) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete Episode ${epNumber(d.number)}?'),
      content: Text('${formatBytes(d.bytes)} will be freed on this device.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await Downloads.instance.remove(d);
  if (context.mounted) showSuccess(context, 'Download deleted');
}

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${group.length} downloads?'),
        content: Text(
          '${titleOf(group.first.media)} · '
          '${formatBytes(group.fold(0, (sum, d) => sum + d.bytes))} will be freed on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final d in [...group]) {
      await Downloads.instance.remove(d);
    }
    if (mounted) showSuccess(context, 'Downloads deleted');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    appBar: AppBar(title: const Text('Downloads')),
    body: ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
        final items = Downloads.instance.items;
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.download_for_offline_outlined,
            title: 'No downloads yet',
            message:
                '${isTv ? 'Hold OK on' : 'Long-press'} an episode or use ⋮ → Download episodes to watch offline.',
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
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                '${items.length} episodes · ${formatBytes(Downloads.instance.totalBytes)} on this device',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
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
                          visualDensity: VisualDensity.compact,
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
        _DownloadShowHeader(
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

class _DownloadShowHeader extends StatelessWidget {
  const _DownloadShowHeader(
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
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 4, 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 40,
                height: 56,
                child: _Img(
                  media['coverImage']?['extraLarge'],
                  color: media['coverImage']?['color'],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleOf(media),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${group.length} ${group.length == 1 ? 'episode' : 'episodes'} · '
                    '${formatBytes(group.fold(0, (sum, d) => sum + d.bytes))}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: Colors.white70,
            ),
            PopupMenuButton<VoidCallback>(
              tooltip: 'Show actions',
              color: _sheet,
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: () => openDetails(context, media),
                  child: const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Open show'),
                  ),
                ),
                PopupMenuItem(
                  value: onDelete,
                  child: const ListTile(
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('Delete all'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile(this.download, this.group);

  final Download download;
  final List<Download> group;

  void _play(BuildContext context) {
    final playable = [
      for (final d in group)
        if (d.status == DownloadStatus.done && d.dub == download.dub) d,
    ]..sort((a, b) => a.number.compareTo(b.number));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          media: download.media,
          source: null,
          sourceName: download.source,
          episodes: [for (final d in playable) d.episode],
          index: playable.indexOf(download),
          dub: download.dub,
        ),
      ),
    );
  }

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
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      onTap: d.status == DownloadStatus.done ? () => _play(context) : null,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 88,
          height: 50,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Colors.white.withValues(alpha: .05),
                child: Center(
                  child: Text(
                    epNumber(d.number),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white24,
                    ),
                  ),
                ),
              ),
              if (d.thumbnail != null)
                _Img(d.thumbnail, transparent: true, decodeWidth: 88),
            ],
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
            style: TextStyle(
              fontSize: 12,
              color: failed ? const Color(0xFFFF8A8E) : Colors.white70,
            ),
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: d.status == DownloadStatus.queued ? 0 : d.progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
                backgroundColor: Colors.white10,
              ),
            ),
        ],
      ),
      trailing: switch (d.status) {
        DownloadStatus.done => IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => _confirmDelete(context, d),
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

// ───────────────────────────── Continue watching ─────────────────────────────

/// Reopens the player where a [WatchHistory] record left off, from downloads when the site can't be reached.
Future<void> resumeWatching(
  BuildContext context,
  Map<String, dynamic> record, {
  List<Episode>? loaded,
}) async {
  final media = record['media'] as Map;
  final number = record['episode'] as num;
  final downloaded = [
    for (final d in Downloads.instance.forMedia(media)) d.episode,
  ];
  Source? source;
  var episodes = loaded ?? const <Episode>[];
  try {
    source = (await sites).where((s) => s.name == record['source']).firstOrNull;
    final site = source;
    if (loaded == null && site != null && context.mounted) {
      episodes = await withCloudflare<List<Episode>>(
        context,
        () => loadEpisodes(site, media),
      );
    }
  } catch (_) {
    if (!downloaded.any((e) => e.number == number)) {
      rethrow; // offline and not downloaded
    }
  }
  if (!episodes.any((e) => e.number == number)) episodes = downloaded;
  final index = episodes.indexWhere((e) => e.number == number);
  if (index == -1) {
    throw Exception(
      source == null
          ? '${record['source']} is no longer one of the top sites'
          : 'Episode ${epNumber(number)} is not on ${source.name} yet',
    );
  }
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        media: media,
        source: source,
        sourceName: record['source'],
        episodes: episodes,
        index: index,
        dub: record['dub'] == true,
        start: Settings.resume
            ? Duration(milliseconds: record['position'] as int? ?? 0)
            : null,
      ),
    ),
  );
}

class ContinueFab extends StatefulWidget {
  const ContinueFab({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final String title, subtitle;
  final Future<void> Function() onPressed;

  @override
  State<ContinueFab> createState() => _ContinueFabState();
}

class _ContinueFabState extends State<ContinueFab> {
  bool busy = false;

  Future<void> _run() async {
    setState(() => busy = true);
    try {
      await widget.onPressed();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Rises and fades in once, instead of popping up when history loads.
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 420),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, 24 * (1 - t)),
        child: Transform.scale(scale: .92 + .08 * t, child: child),
      ),
    ),
    child: _fab(context),
  );

  Widget _fab(BuildContext context) => FloatingActionButton.extended(
    autofocus: isTv, // the details page's play button on TV
    tooltip: '${widget.title} · ${widget.subtitle}',
    onPressed: busy ? null : _run,
    icon: busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        : const Icon(Icons.play_arrow_rounded, size: 28),
    label: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .55,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            widget.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    ),
  );
}

// ───────────────────────────── Shared bits ─────────────────────────────

class _Img extends StatelessWidget {
  const _Img(
    this.url, {
    this.color,
    this.alignment = Alignment.center,
    this.transparent = false,
    this.decodeWidth,
  });

  final String? url;
  final String? color;
  final Alignment alignment;
  final bool transparent; // draw over a placeholder instead of a filled box

  /// Logical width to decode at. Episode stills often come at 1080p, which is ~8 MB each once decoded;
  /// a list of them thrashes the image cache and stutters while scrolling.
  final double? decodeWidth;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return ColoredBox(
      color: transparent
          ? Colors.transparent
          : _hex(color)?.withValues(alpha: .3) ?? const Color(0xFF1A1A24),
      child: url == null
          ? null
          : Image.network(
              url,
              fit: BoxFit.cover,
              alignment: alignment,
              cacheWidth: decodeWidth == null
                  ? null
                  : (decodeWidth! * MediaQuery.devicePixelRatioOf(context))
                        .round(),
              frameBuilder: (context, child, frame, sync) => sync
                  ? child
                  : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 300),
                      child: child,
                    ),
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
    );
  }
}

class _Score extends StatelessWidget {
  const _Score(this.score, {this.compact = false});

  final int score;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 6 : 10,
      vertical: compact ? 3 : 6,
    ),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.star_rounded,
          size: compact ? 12 : 16,
          color: const Color(0xFFFFC857),
        ),
        const SizedBox(width: 3),
        Text(
          '$score%',
          style: TextStyle(
            fontSize: compact ? 11 : 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}
