import 'dart:async';

import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'tracker.dart';
import 'cloudflare.dart';
import 'downloads.dart';
import 'history.dart';
import 'player.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';

const background = Color(0xFF0A0A0F);
const _sheet = Color(0xFF14141C);

Future<void> openDetails(
  BuildContext context,
  Map media, {
  VoidCallback? onBack,
}) async {
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailsScreen(media)),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Analytics.screen('/', title: 'Home');
    _syncPending();
    checkForUpdate(context, quiet: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  void _reloadLists() => setState(() {
    lists = Tracker.lists();
    history = WatchHistory.all();
  });

  Future<void> _refresh() async {
    setState(() {
      viewer = Tracker.viewer();
      lists = Tracker.lists();
      trending = Tracker.trending();
      season = Tracker.season();
      history = WatchHistory.all();
    });
    _syncPending();
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

  @override
  Widget build(BuildContext context) {
    final (name, year) = AniList.currentSeason;
    final seasonTitle =
        'This season · ${name[0]}${name.substring(1).toLowerCase()} $year';
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
              ] else ...[
                _Hero(
                  items: snap.data?.take(6).toList() ?? const [],
                  loading: snap.connectionState != ConnectionState.done,
                  error: snap.error,
                  onRetry: _refresh,
                ),
                if (Tracker.signedIn)
                  FutureBuilder(
                    future: lists,
                    builder: (context, snap) {
                      const title = 'Continue watching · This season';
                      if (snap.connectionState != ConnectionState.done) {
                        return const ShelfSkeleton(title: title);
                      }
                      final airing = (snap.data?['CURRENT'] ?? const [])
                          .where(_airingNow)
                          .toList();
                      return airing.isEmpty
                          ? const SizedBox.shrink()
                          : _Shelf(title, airing, onBack: _reloadLists);
                    },
                  ),
                if (!Tracker.signedIn)
                  _SignInCard(onTap: _signIn)
                else
                  FutureBuilder(
                    future: lists,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const ShelfSkeleton(title: 'Continue watching');
                      }
                      if (snap.hasError) {
                        return _Section(
                          'Your list',
                          child: ErrorState(
                            snap.error!,
                            compact: true,
                            onRetry: _reloadLists,
                          ),
                        );
                      }
                      final watching = snap.data!['CURRENT'] ?? const [];
                      final current = watching
                          .where((m) => !_airingNow(m))
                          .toList(); // airing ones are in the top row
                      final planning = snap.data!['PLANNING'] ?? const [];
                      if (watching.isEmpty && planning.isEmpty) {
                        return EmptyState(
                          compact: true,
                          icon: Icons.video_library_outlined,
                          title: 'Your list is empty',
                          message:
                              'Shows you watch or plan to watch show up here.',
                          action: FilledButton.tonalIcon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const SearchScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.search_rounded),
                            label: const Text('Find a show'),
                          ),
                        );
                      }
                      return Column(
                        children: [
                          if (current.isNotEmpty)
                            _Shelf(
                              'Continue watching',
                              current,
                              onBack: _reloadLists,
                            ),
                          if (planning.isNotEmpty)
                            _Shelf(
                              'Plan to watch',
                              planning,
                              onBack: _reloadLists,
                            ),
                        ],
                      );
                    },
                  ),
                _recentlyWatched,
                _shelf(
                  seasonTitle,
                  season,
                  onRetry: () => setState(() => season = Tracker.season()),
                ),
                _shelf(
                  'Trending now',
                  trending,
                  onRetry: _refresh,
                  showError: false,
                ), // the hero already shows it
              ],
              const SizedBox(
                height: 96,
              ), // room for the continue-watching button
            ],
          ),
        ),
      ),
    );
  }

  Widget get _recentlyWatched => FutureBuilder(
    future: history,
    builder: (context, snap) => snap.data?.isNotEmpty ?? false
        ? _Shelf('Recently watched', [
            for (final record in snap.data!) record['media'],
          ], onBack: _reloadLists)
        : const SizedBox.shrink(),
  );

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
            style: TextStyle(color: Colors.white54),
          ),
        );
      }
      return _Shelf(title, snap.data!, onBack: _reloadLists);
    },
  );
}

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
  const _Shelf(this.title, this.items, {this.onBack});

  final String title;
  final List items;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      SizedBox(
        height: 272,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, i) =>
              SizedBox(width: 136, child: PosterCard(items[i], onBack: onBack)),
        ),
      ),
    ],
  );
}

class PosterCard extends StatelessWidget {
  const PosterCard(this.media, {super.key, this.onBack});

  final Map media;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final progress = media['mediaListEntry']?['progress'] as int?;
    final aired = media['nextAiringEpisode']?['episode'] as int?;
    final total =
        media['episodes'] as int? ?? (aired == null ? null : aired - 1);
    return GestureDetector(
      onTap: () => openDetails(context, media, onBack: onBack),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Img(
                    media['coverImage']['extraLarge'],
                    color: media['coverImage']['color'],
                  ),
                  if (media['averageScore'] != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _Score(media['averageScore'], compact: true),
                    ),
                  if (progress != null && total != null && total > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: (progress / total).clamp(0.0, 1.0).toDouble(),
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
          if (progress != null)
            Text(
              'EP $progress${total == null ? '' : ' / $total'}',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Search ─────────────────────────────

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.filters});

  /// Opens browsing these right away ("See all", a genre chip) instead of an empty search.
  final SearchFilters? filters;

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
        autofocus: widget.filters == null,
        textInputAction: TextInputAction.search,
        onChanged: _search,
        onSubmitted: (text) => _search(text, now: true),
        decoration: _searchDecoration('Search anime'),
      ),
      actions: [
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
  const DetailsScreen(this.media, {super.key});

  final Map media;

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
  bool dub = Settings.preferDub, expanded = false;

  Map get media => widget.media;

  @override
  void initState() {
    super.initState();
    Analytics.screen('/details', title: titleOf(media));
    _loadSites();
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

  void _downloadSeason(Source site, List<Episode> list) {
    final count = list.where((e) {
      final d = Downloads.instance.entry(media, e.number, dub);
      return d == null || d.status == DownloadStatus.failed;
    }).length;
    Downloads.instance.enqueue(media, site.name, list, dub: dub, season: list);
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
    final description = (media['description'] as String? ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();

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
            sliver: SliverList.list(
              children: [
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
                      child: _Img(
                        media['coverImage']['extraLarge'],
                        color: media['coverImage']['color'],
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
                              color: Colors.white54,
                            ),
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
                        Chip(
                          label: Text('$genre'),
                          visualDensity: VisualDensity.compact,
                          side: BorderSide.none,
                          backgroundColor: Colors.white.withValues(alpha: .06),
                        ),
                    ],
                  ),
                ],
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => setState(() => expanded = !expanded),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      alignment: Alignment.topCenter,
                      child: Text(
                        description,
                        maxLines: expanded ? null : 4,
                        overflow: expanded ? null : TextOverflow.fade,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
                FutureBuilder(
                  future: relations,
                  builder: (context, snap) => Column(
                    children: [
                      for (final (type, related)
                          in snap.data ?? const <(String, Map)>[])
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _RelationTile(type, related),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    const Text(
                      'Episodes',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('SUB')),
                        ButtonSegment(value: true, label: Text('DUB')),
                      ],
                      selected: {dub},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
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
                              value: () => _downloadSeason(site, list),
                              child: const ListTile(
                                leading: Icon(Icons.download_rounded),
                                title: Text('Download season'),
                              ),
                            ),
                            if (Tracker.signedIn)
                              PopupMenuItem(
                                value: () => _markWatched(
                                  list.fold(
                                    0,
                                    (n, e) =>
                                        e.number > n ? e.number.toInt() : n,
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
              ],
            ),
          ),
          _episodeList(progress),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

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
          final next = list?.indexWhere((e) => e.number > progress) ?? -1;
          if (list == null || next == -1) return const SizedBox.shrink();
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
  Widget _episodeSliver(List<Episode> list, int progress, Source? site) {
    final playable = site != null
        ? list
        : [
            for (final e in list)
              if (Downloads.instance.find(media, e.number) != null) e,
          ];
    return SliverList.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final episode = list[i];
        final watched = episode.number <= progress;
        final saved = site != null || playable.contains(episode);
        return _EpisodeTile(
          episode,
          watched: watched,
          onLongPress: () => _markWatched(
            watched ? episode.number.ceil() - 1 : episode.number.toInt(),
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
                      Downloads.instance.forMedia(media).firstOrNull?.source,
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
                  style: TextStyle(color: Colors.white54, fontSize: 13),
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
                        color: Colors.white54,
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
    this.onLongPress,
    this.trailing,
  });

  final Episode episode;
  final bool watched;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final thumbnail = episode.thumbnail;
    final title = episode.title;
    final overview = episode.overview;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 128,
                height: 72,
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
                    if (thumbnail != null) _Img(thumbnail, transparent: true),
                    if (watched)
                      const ColoredBox(
                        color: Color(0x99000000),
                        child: Center(
                          child: Icon(
                            Icons.check_circle_rounded,
                            color: Colors.white,
                          ),
                        ),
                      )
                    else if (thumbnail != null)
                      Center(
                        child: Icon(
                          Icons.play_circle_fill_rounded,
                          size: 30,
                          color: Colors.white.withValues(alpha: .9),
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
                    'Episode ${epNumber(episode.number)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: watched ? Colors.white54 : Colors.white,
                    ),
                  ),
                  if (title != null)
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                  if (overview != null)
                    Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Colors.white38,
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
    );
  }
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

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    appBar: AppBar(title: const Text('Downloads')),
    body: ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
        final items = Downloads.instance.items;
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.download_for_offline_outlined,
            title: 'No downloads yet',
            message:
                'Tap the download icon next to an episode to watch it offline.',
          );
        }
        final shows = <Object?, List<Download>>{};
        for (final d in items) {
          shows.putIfAbsent(d.media['id'], () => []).add(d);
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                '${items.length} episodes · ${formatBytes(Downloads.instance.totalBytes)} on this device',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            for (final group in shows.values) ...[
              _DownloadShowHeader(group),
              for (final d in [
                ...group,
              ]..sort((a, b) => a.number.compareTo(b.number)))
                _DownloadTile(d, group),
            ],
          ],
        );
      },
    ),
  );
}

class _DownloadShowHeader extends StatelessWidget {
  const _DownloadShowHeader(this.group);

  final List<Download> group;

  @override
  Widget build(BuildContext context) {
    final media = group.first.media;
    return InkWell(
      onTap: () => openDetails(context, media),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
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
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
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
              if (d.thumbnail != null) _Img(d.thumbnail, transparent: true),
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
              color: failed ? const Color(0xFFFF8A8E) : Colors.white54,
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

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    tooltip: '${widget.title} · ${widget.subtitle}',
    onPressed: busy ? null : _run,
    child: busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        : const Icon(Icons.play_arrow_rounded, size: 32),
  );
}

// ───────────────────────────── Shared bits ─────────────────────────────

class _Img extends StatelessWidget {
  const _Img(
    this.url, {
    this.color,
    this.alignment = Alignment.center,
    this.transparent = false,
  });

  final String? url;
  final String? color;
  final Alignment alignment;
  final bool transparent; // draw over a placeholder instead of a filled box

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
