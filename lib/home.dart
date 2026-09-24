import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'details.dart';
import 'downloads.dart';
import 'downloads_screen.dart';
import 'history.dart';
import 'notifications.dart';
import 'player.dart';
import 'search.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';

/// The app's top level: Home, Search, Downloads and Settings. Phones get a navigation bar (a rail from 600dp
/// wide), TV a navigation drawer along the left edge that widens with labels while it has focus. Each page keeps
/// its state while another is shown.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

typedef _Destination = (IconData icon, IconData selected, String label);

const _destinations = <_Destination>[
  (Icons.home_outlined, Icons.home_rounded, 'Home'),
  (Icons.search_rounded, Icons.search_rounded, 'Search'),
  (
    Icons.download_for_offline_outlined,
    Icons.download_for_offline_rounded,
    'Downloads',
  ),
  (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
];

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late Future<Map<String, dynamic>?> viewer = Tracker.viewer();
  late Future<Map<String, List>> lists = Tracker.lists();
  late Future<List> trending = Tracker.trending();
  late Future<List> season = Tracker.season();

  /// Where you stopped in each show, newest first; on-device, so it's there even when AniList isn't.
  late Future<List<WatchRecord>> history = WatchHistory.all();

  late Future<List<Map>> released = _released();

  int tab = 0;
  final _visited = {0}; // pages are built the first time they're opened

  /// New episodes of the shows on your watching list and the ones you watched recently.
  Future<List<Map>> _released() async {
    final watching = await lists.then(
      (l) => l['CURRENT'] ?? const [],
      onError: (Object _) => const [], // still check the recently watched ones
    );
    return AniList.airedThisWeek([
      for (final m in [...watching, for (final r in await history) r.media])
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
    listenTv(resume: _resumeFromLauncher, search: _voiceSearch);
    if (isTv) {
      onRemoteSearch = _remoteSearch;
      onLeftEdge = () {
        if (ModalRoute.of(context)?.isCurrent != true) return false;
        _openDrawer();
        return true;
      };
    }
    checkForUpdate(context, quiet: true);
  }

  /// The remote's search key: voice search on the Search page, from anywhere but the player.
  void _voiceSearch() {
    if (PlayerScreen.showing) return;
    Navigator.popUntil(context, (route) => route.isFirst);
    voiceSearch.value = true;
    isTv ? _tvSelect(1) : _select(1);
  }

  /// The phone remote's search box: Search on the TV, running what's typed there. Not while something plays.
  void _remoteSearch(String? query) {
    if (PlayerScreen.showing) return;
    Navigator.popUntil(context, (route) => route.isFirst);
    if (tab != 1) _tvSelect(1);
    if (query != null) remoteQuery.value = query;
  }

  @override
  void dispose() {
    onLeftEdge = null;
    onRemoteSearch = null;
    WidgetsBinding.instance.removeObserver(this);
    for (final node in _drawer) {
      node.dispose();
    }
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
    if (!mounted) return;
    setState(() {
      lists = Tracker.lists();
      history = WatchHistory.all();
      released = _released();
    });
    _scheduleNotifications();
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
    final record = await WatchHistory.byId(id);
    if (!mounted) return;
    if (record == null) return _openFromNotification(id);
    Navigator.popUntil(context, (route) => route.isFirst);
    try {
      await resumeWatching(context, record);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reloadLists();
  }

  /// Keeps the background new-episode check current with recently watched shows and the AniList sign-in.
  Future<void> _scheduleNotifications() async {
    final recent = await history;
    syncWatchNext(recent);
    if (Settings.episodeNotifications &&
        (Tracker.signedIn || recent.isNotEmpty)) {
      EpisodeNotifications.requestPermission();
    }
    await EpisodeNotifications.refresh([for (final r in recent) r.media]);
  }

  Future<void> _signIn() async {
    try {
      final name = await Tracker.signIn(context);
      if (name == null) return; // closed without signing in
      if (mounted) showSuccess(context, 'Signed in as $name');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _refresh();
  }

  /// Settings may have changed the sign-in or the home sections by the time you leave it.
  void _select(int i) {
    if (i == tab) return;
    FocusManager.instance.primaryFocus
        ?.unfocus(); // a search box keeps its keyboard up otherwise
    if (tab == 3) _refresh();
    if (i == 0) _reloadLists();
    setState(() {
      tab = i;
      _visited.add(i);
    });
  }

  Widget _page(int i) => switch (i) {
    0 => _HomeFeed(this),
    1 => const SearchScreen(),
    2 => DownloadsScreen(onBrowse: () => _select(0)),
    _ => const SettingsScreen(),
  };

  /// The pages, built once visited; only the shown one takes focus or runs animations.
  Widget get _pages => IndexedStack(
    index: tab,
    children: [
      for (var i = 0; i < _destinations.length; i++)
        ExcludeFocus(
          excluding: i != tab,
          child: TickerMode(
            enabled: i == tab,
            child: _visited.contains(i) ? _page(i) : const SizedBox(),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (isTv) return _tv();
    // Back leaves another page for Home before it leaves the app.
    return PopScope(
      canPop: tab == 0,
      onPopInvokedWithResult: (didPop, _) => didPop ? null : _select(0),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= 600) {
            return Scaffold(
              body: Row(
                children: [
                  SafeArea(
                    right: false,
                    child: NavigationRail(
                      selectedIndex: tab,
                      onDestinationSelected: _select,
                      groupAlignment: 0,
                      destinations: [
                        for (final (icon, selected, label) in _destinations)
                          NavigationRailDestination(
                            icon: Icon(icon),
                            selectedIcon: Icon(selected),
                            label: Text(label),
                          ),
                      ],
                    ),
                  ),
                  Expanded(child: _pages),
                ],
              ),
            );
          }
          return Scaffold(
            body: _pages,
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: _select,
              destinations: [
                for (final (icon, selected, label) in _destinations)
                  NavigationDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selected),
                    label: label,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ───────────────────────────── TV ─────────────────────────────

  final _drawer = List.generate(
    _destinations.length,
    (i) => FocusNode(debugLabel: 'drawer $i'),
  );
  bool _drawerOpen = false;
  FocusNode? _lastInPage;

  void _openDrawer() {
    _lastInPage = FocusManager.instance.primaryFocus;
    setState(() => _drawerOpen = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _drawer[tab].requestFocus(),
    );
  }

  /// Back into the page: where focus was, or the page's first focusable thing.
  void _closeDrawer({bool fresh = false}) {
    final back = _lastInPage;
    setState(() => _drawerOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!fresh && back != null && back.context?.mounted == true) {
        back.requestFocus();
      } else {
        _drawer[tab].focusInDirection(TraversalDirection.right);
      }
    });
  }

  void _tvSelect(int i) {
    _select(i);
    _closeDrawer(fresh: true);
  }

  KeyEventResult _pageKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && !primary.focusInDirection(TraversalDirection.left)) {
      _openDrawer();
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _drawerKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final i = _drawer.indexWhere((n) => n.hasPrimaryFocus);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp when i > 0:
        _drawer[i - 1].requestFocus();
      case LogicalKeyboardKey.arrowDown when i < _drawer.length - 1:
        _drawer[i + 1].requestFocus();
      case LogicalKeyboardKey.arrowRight:
        _closeDrawer();
      case LogicalKeyboardKey.arrowUp ||
          LogicalKeyboardKey.arrowDown ||
          LogicalKeyboardKey.arrowLeft:
        break; // the drawer's ends
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Back from a page opens the drawer; from the drawer it goes Home, then leaves the app.
  Widget _tv() => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (!_drawerOpen) return _openDrawer();
      if (tab != 0) return _tvSelect(0);
      SystemNavigator.pop();
    },
    child: Scaffold(
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: _TvDrawer.collapsed),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _pageKey,
              child: _pages,
            ),
          ),
          // The drawer only takes focus while it's open, so Up and Down never wander into it.
          ExcludeFocus(
            excluding: !_drawerOpen,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _drawerKey,
              child: FutureBuilder(
                future: viewer,
                builder: (context, snap) => _TvDrawer(
                  open: _drawerOpen,
                  selected: tab,
                  focusNodes: _drawer,
                  avatar: snap.data?['avatar']?['large'] as String?,
                  onSelect: _tvSelect,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The TV navigation drawer: icons along the edge, widening over the page with labels (and a scrim behind) while
/// it has focus. The focused item turns solid; the current page stays tinted. Settings sits at the bottom.
class _TvDrawer extends StatelessWidget {
  const _TvDrawer({
    required this.open,
    required this.selected,
    required this.focusNodes,
    required this.onSelect,
    this.avatar,
  });

  static const collapsed = 80.0, expanded = 256.0;

  final bool open;
  final int selected;
  final List<FocusNode> focusNodes;
  final ValueChanged<int> onSelect;
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    const ease = Duration(milliseconds: 220);
    Widget item(int i) {
      final (icon, selectedIcon, label) = _destinations[i];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ListenableBuilder(
          listenable: focusNodes[i],
          builder: (context, _) {
            final focused = focusNodes[i].hasFocus;
            final color = focused
                ? scheme.surface
                : i == selected
                ? scheme.primary
                : scheme.onSurfaceVariant;
            return InkWell(
              focusNode: focusNodes[i],
              onTap: () => onSelect(i),
              borderRadius: BorderRadius.circular(24),
              focusColor: Colors.transparent,
              child: AnimatedContainer(
                duration: ease,
                curve: Curves.easeOutCubic,
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: focused
                      ? scheme.onSurface
                      : i == selected && open
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    if (i == 3 && avatar != null)
                      CircleAvatar(
                        radius: 12,
                        backgroundImage: NetworkImage(avatar!),
                      )
                    else
                      Icon(
                        i == selected ? selectedIcon : icon,
                        size: 24,
                        color: color,
                      ),
                    const SizedBox(width: 20),
                    Flexible(
                      child: AnimatedOpacity(
                        opacity: open ? 1 : 0,
                        duration: ease,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: color),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Stack(
      children: [
        // The scrim behind the open drawer.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: ease,
            child: SizedBox(
              width: 560,
              height: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      scheme.surface,
                      scheme.surface.withValues(alpha: .85),
                      scheme.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, .4, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedContainer(
          duration: ease,
          curve: Curves.easeOutCubic,
          width: open ? expanded : collapsed,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: expanded,
            maxWidth: expanded,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/icon/aniview_icon.png',
                        width: 32,
                        height: 32,
                        cacheWidth: 96,
                      ),
                    ),
                  ),
                  const Spacer(),
                  for (var i = 0; i < 3; i++) item(i),
                  const Spacer(),
                  item(3),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── The home page ─────────────────────────────

/// Home's rows. On phones a featured carousel leads; on TV the focused show fills an immersive backdrop above the
/// rows (the Google TV immersive list).
class _HomeFeed extends StatelessWidget {
  const _HomeFeed(this.home);

  final _HomeScreenState home;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: home.trending,
    builder: (context, snap) {
      final offline = snap.hasError && _downloaded.isNotEmpty;
      final rows = <Widget>[
        // Offline: go straight to what can play.
        if (offline) ...[
          _OfflineBanner(onRetry: home._refresh),
          _recentlyWatched(),
          MediaRow('Downloaded', _downloaded, onBack: home._reloadLists),
        ] else
          for (final (section, shown) in Settings.homeSections)
            if (shown && !(isTv && section == HomeSection.featured))
              _section(context, section, snap),
      ];
      return isTv ? _tv(context, snap, rows) : _phone(context, snap, rows);
    },
  );

  Widget _phone(
    BuildContext context,
    AsyncSnapshot<List> snap,
    List<Widget> rows,
  ) {
    final featured =
        Settings.homeSections.contains((HomeSection.featured, true)) &&
        !(snap.hasError && _downloaded.isNotEmpty);
    return Scaffold(
      floatingActionButton: FutureBuilder(
        future: home.history,
        builder: (context, snap) {
          final record = snap.data?.firstOrNull;
          if (record == null) return const SizedBox.shrink();
          return PlayAction(
            fab: true,
            title: 'Continue EP ${epNumber(record.episode)}',
            subtitle: record.show.title,
            onPressed: () async {
              await resumeWatching(context, record);
              home._reloadLists();
            },
          );
        },
      ),
      body: RefreshIndicator(
        onRefresh: home._refresh,
        edgeOffset: MediaQuery.paddingOf(context).top,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (featured)
              SliverToBoxAdapter(
                child: _Featured(
                  items: snap.data?.take(6).toList() ?? const [],
                  loading: !snap.hasData && !snap.hasError,
                  error: snap.error,
                  onRetry: home._refresh,
                ),
              )
            else
              SliverAppBar(
                floating: true,
                title: Text(
                  'AniView',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            SliverList.list(children: rows),
            // Clear of the continue button.
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  Widget _tv(
    BuildContext context,
    AsyncSnapshot<List> snap,
    List<Widget> rows,
  ) {
    final height = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        ValueListenableBuilder(
          valueListenable: focusedMedia,
          builder: (context, focused, _) {
            final media = focused ?? snap.data?.firstOrNull;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: media == null
                  ? const SizedBox.expand()
                  : _Immersive(media, key: ValueKey(media['id'])),
            );
          },
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: height * .44),
            Expanded(
              // Rows scrolled past fade out under the backdrop instead of covering it.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0, .08],
                ).createShader(bounds),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (snap.hasError && _downloaded.isEmpty)
                      ErrorState(
                        snap.error!,
                        compact: true,
                        onRetry: home._refresh,
                      ),
                    ...rows,
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Shows with a finished download.
  List<Map> get _downloaded => {
    for (final d in Downloads.instance.items)
      if (d.status == DownloadStatus.done) d.media['id']: d.media,
  }.values.toList();

  /// Whether [section] is the first row, which takes focus on TV.
  bool _first(HomeSection section) =>
      Settings.homeSections
          .where((s) => s.$2 && s.$1 != HomeSection.featured)
          .firstOrNull
          ?.$1 ==
      section;

  Widget _section(
    BuildContext context,
    HomeSection section,
    AsyncSnapshot<List> trendingSnap,
  ) {
    final showAiring = Settings.homeSections.contains((
      HomeSection.airing,
      true,
    ));
    final first = isTv && _first(section);
    return switch (section) {
      HomeSection.featured => const SizedBox.shrink(), // the carousel
      HomeSection.newEpisodes => FutureBuilder(
        future: home.released,
        builder: (context, snap) {
          final aired = snap.data ?? const [];
          if (aired.isEmpty) return const SizedBox.shrink();
          return MediaRow(
            section.label,
            [for (final a in aired) a['media']],
            autofocus: first,
            onBack: home._reloadLists,
            subtitles: [
              for (final a in aired)
                'EP ${a['episode']} · ${_ago(a['airingAt'] as int)}',
            ],
          );
        },
      ),
      HomeSection.airing when Tracker.signedIn => FutureBuilder(
        future: home.lists,
        builder: (context, snap) {
          if (!snap.hasData && !snap.hasError) {
            return RowSkeleton(title: section.label);
          }
          final airing = (snap.data?['CURRENT'] ?? const [])
              .where(_airingNow)
              .toList();
          return airing.isEmpty
              ? const SizedBox.shrink()
              : MediaRow(
                  section.label,
                  airing,
                  autofocus: first,
                  onBack: home._reloadLists,
                );
        },
      ),
      HomeSection.watching when !Tracker.signedIn => _SignInCard(
        onTap: home._signIn,
        autofocus: first,
      ),
      HomeSection.watching ||
      HomeSection.planning when Tracker.signedIn => FutureBuilder(
        future: home.lists,
        builder: (context, snap) {
          if (!snap.hasData && !snap.hasError) {
            return RowSkeleton(title: section.label);
          }
          if (snap.hasError) {
            return section == HomeSection.planning
                ? const SizedBox.shrink() // shown once, by watching
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Your list'),
                      ErrorState(
                        snap.error!,
                        compact: true,
                        onRetry: home._reloadLists,
                      ),
                    ],
                  );
          }
          final watching = snap.data!['CURRENT'] ?? const [];
          final planning = snap.data!['PLANNING'] ?? const [];
          if (section == HomeSection.planning) {
            return planning.isEmpty
                ? const SizedBox.shrink()
                : MediaRow(
                    section.label,
                    planning,
                    autofocus: first,
                    onBack: home._reloadLists,
                  );
          }
          if (watching.isEmpty && planning.isEmpty) {
            return EmptyState(
              compact: true,
              icon: Icons.video_library_outlined,
              title: 'Your list is empty',
              message: 'Shows you watch or plan to watch show up here.',
              action: FilledButton.tonalIcon(
                onPressed: () => home._select(1),
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
              : MediaRow(
                  section.label,
                  current,
                  autofocus: first,
                  onBack: home._reloadLists,
                );
        },
      ),
      HomeSection.recent => _recentlyWatched(autofocus: first),
      HomeSection.season => _row(
        context,
        () {
          final (name, year) = AniList.currentSeason;
          return 'This season · ${name[0]}${name.substring(1).toLowerCase()} $year';
        }(),
        home.season,
        autofocus: first,
        seeAll: SearchFilters(
          season: AniList.currentSeason.$1,
          year: AniList.currentSeason.$2,
          sort: 'POPULARITY_DESC',
        ),
      ),
      HomeSection.trending => _row(
        context,
        section.label,
        home.trending,
        autofocus: first,
        // The carousel (or on TV the backdrop's error) already shows it.
        showError:
            !isTv &&
            !Settings.homeSections.contains((HomeSection.featured, true)),
        seeAll: const SearchFilters(sort: 'TRENDING_DESC'),
      ),
      _ => const SizedBox.shrink(), // list rows while signed out
    };
  }

  Widget _recentlyWatched({bool autofocus = false}) => FutureBuilder(
    future: home.history,
    builder: (context, snap) {
      final records = snap.data ?? const [];
      if (records.isEmpty) return const SizedBox.shrink();
      return MediaRow(
        'Recently watched',
        [for (final record in records) record.media],
        autofocus: autofocus,
        onBack: home._reloadLists,
        subtitles: [
          for (final r in records)
            'EP ${epNumber(r.episode)}'
                '${r.position > Duration.zero ? ' · ${formatDuration(r.position)}' : ''}',
        ],
        onLongPress: (i) => _removeFromHistory(context, records[i]),
      );
    },
  );

  Future<void> _removeFromHistory(
    BuildContext context,
    WatchRecord record,
  ) async {
    final remove = await showSheet<bool>(
      context,
      (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sheetTitle(context, record.show.title),
            ListTile(
              autofocus: isTv,
              leading: const Icon(Icons.history_toggle_off_rounded),
              title: const Text('Remove from recently watched'),
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (remove != true) return;
    await WatchHistory.remove(record.media);
    home._reloadLists();
  }

  Widget _row(
    BuildContext context,
    String title,
    Future<List> future, {
    bool showError = true,
    bool autofocus = false,
    SearchFilters? seeAll,
  }) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      if (!snap.hasData && !snap.hasError) {
        return RowSkeleton(title: title);
      }
      if (snap.hasError) {
        return !showError
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(title),
                  ErrorState(
                    snap.error!,
                    compact: true,
                    onRetry: home._refresh,
                  ),
                ],
              );
      }
      if (snap.data!.isEmpty) return const SizedBox.shrink();
      return MediaRow(
        title,
        snap.data!,
        autofocus: autofocus,
        onBack: home._reloadLists,
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

/// Airing now: still releasing, or from the current season.
bool _airingNow(dynamic media) {
  final (season, year) = AniList.currentSeason;
  return media['status'] == 'RELEASING' ||
      (media['season'] == season && media['seasonYear'] == year);
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: EdgeInsets.fromLTRB(side, 16, side - 8, 0),
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
    ),
  );
}

/// Phones: trending shows as full-bleed pages at the top of home, under the status bar.
class _Featured extends StatefulWidget {
  const _Featured({
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
  State<_Featured> createState() => _FeaturedState();
}

class _FeaturedState extends State<_Featured> {
  final controller = PageController();
  int page = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.width * 1.2).clamp(360.0, size.height * .66);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          if (widget.loading)
            const Positioned.fill(child: Skeleton(radius: 0))
          else if (widget.error != null)
            Positioned.fill(
              child: ErrorState(widget.error!, onRetry: widget.onRetry),
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
              itemBuilder: (context, i) => _FeaturedPage(widget.items[i]),
            ),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, 8, side, 0),
              child: Text(
                'AniView',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
          if (!widget.loading && widget.items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == page ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == page
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: .3),
                        borderRadius: BorderRadius.circular(4),
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

class _FeaturedPage extends StatelessWidget {
  const _FeaturedPage(this.media);

  final Map media;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final score = Show(media).score;
    return GestureDetector(
      onTap: () => openDetails(context, media),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Artwork(
            Show(media).cover,
            color: Show(media).color,
            alignment: Alignment.topCenter,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface.withValues(alpha: .7),
                  scheme.surface.withValues(alpha: 0),
                  scheme.surface.withValues(alpha: .85),
                  scheme.surface,
                ],
                stops: const [0, .25, .72, 1],
              ),
            ),
          ),
          Positioned(
            left: side,
            right: side,
            bottom: 36,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleOf(media),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (score != null) '★ $score%',
                    mediaMeta(media, genres: 3),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => openDetails(context, media),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Watch now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// TV: the focused show's 16:9 art towards the top right under a cinematic scrim, its title, details and synopsis
/// on the left, above the rows.
class _Immersive extends StatelessWidget {
  const _Immersive(this.media, {super.key});

  final Map media;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final show = Show(media);
    final description = plainText(show.description);
    final score = show.score;
    final airing = airingLabel(media);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          right: 0,
          width: size.width * .7,
          height: size.width * .7 * 9 / 16,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(
                show.backdrop,
                color: show.color,
                alignment: Alignment.topCenter,
                full: true,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      scheme.surface,
                      scheme.surface.withValues(alpha: .6),
                      scheme.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, .35, .7],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      scheme.surface.withValues(alpha: 0),
                      scheme.surface,
                    ],
                    stops: const [.45, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: tvMargin,
          top: 24,
          width: size.width * .45,
          height: size.height * .44 - 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                titleOf(media),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (score != null) ...[
                    Pill.score(score),
                    const SizedBox(width: 8),
                  ],
                  if (airing != null) ...[
                    Pill(airing, icon: Icons.schedule_rounded),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      mediaMeta(media, genres: 3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.onTap, this.autofocus = false});

  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ScrollAnchor(
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 24, side, 0),
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(16),
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
                        'Track what you watch, and see your lists here',
                        style: text.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  autofocus: autofocus,
                  onPressed: onTap,
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
