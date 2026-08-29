import 'dart:async';

import 'package:flutter/material.dart';

import 'anilist.dart';
import 'cloudflare.dart';
import 'history.dart';
import 'player.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';

const background = Color(0xFF0A0A0F);
const _sheet = Color(0xFF14141C);

Future<void> openDetails(BuildContext context, Map media, {VoidCallback? onBack}) async {
  await Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(media)));
  onBack?.call();
}

Color? _hex(String? hex) => hex == null || hex.length != 7 ? null : Color(int.parse('FF${hex.substring(1)}', radix: 16));

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

class _HomeScreenState extends State<HomeScreen> {
  late Future<Map<String, dynamic>?> viewer = AniList.viewer();
  late Future<Map<String, List>> lists = AniList.lists();
  late Future<List> trending = AniList.trending();
  late Future<List> season = AniList.season();
  late Future<Map<String, dynamic>?> lastWatched = WatchHistory.latest();

  void _reloadLists() => setState(() {
        lists = AniList.lists();
        lastWatched = WatchHistory.latest();
      });

  Future<void> _refresh() async {
    setState(() {
      viewer = AniList.viewer();
      lists = AniList.lists();
      trending = AniList.trending();
      season = AniList.season();
      lastWatched = WatchHistory.latest();
    });
    try {
      await Future.wait([lists, trending, season]);
    } catch (_) {} // each section shows its own error state
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (mounted) _refresh();
  }

  Future<void> _account() async {
    if (AniList.token != null) return _openSettings();
    if (AniList.clientId.isEmpty) {
      showError(context, 'This build has no AniList client id (--dart-define=ANILIST_CLIENT_ID)');
      return;
    }
    try {
      await AniList.login(context);
      if (AniList.token == null) return; // closed without signing in
      final me = await AniList.viewer();
      if (mounted) showSuccess(context, 'Signed in as ${me?['name'] ?? 'AniList user'}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final (name, year) = AniList.currentSeason;
    final seasonTitle = 'This season · ${name[0]}${name.substring(1).toLowerCase()} $year';
    return Scaffold(
      backgroundColor: background,
      floatingActionButton: FutureBuilder(
        future: lastWatched,
        builder: (context, snap) {
          final record = snap.data;
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
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            FutureBuilder(
              future: trending,
              builder: (context, snap) => _Hero(
                items: snap.data?.take(6).toList() ?? const [],
                loading: snap.connectionState != ConnectionState.done,
                error: snap.error,
                onRetry: _refresh,
                header: _TopBar(viewer: viewer, onAccount: _account, onSettings: _openSettings),
              ),
            ),
            if (AniList.token == null)
              _SignInCard(onTap: _account)
            else
              FutureBuilder(
                future: lists,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const ShelfSkeleton(title: 'Continue watching');
                  }
                  if (snap.hasError) {
                    return _Section('Your AniList', child: ErrorState(snap.error!, compact: true, onRetry: _reloadLists));
                  }
                  final current = snap.data!['CURRENT'] ?? const [];
                  final planning = snap.data!['PLANNING'] ?? const [];
                  if (current.isEmpty && planning.isEmpty) {
                    return EmptyState(
                      compact: true,
                      icon: Icons.video_library_outlined,
                      title: 'Your list is empty',
                      message: 'Shows you watch or plan to watch on AniList show up here.',
                      action: FilledButton.tonalIcon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
                        icon: const Icon(Icons.search_rounded),
                        label: const Text('Find a show'),
                      ),
                    );
                  }
                  return Column(
                    children: [
                      if (current.isNotEmpty) _Shelf('Continue watching', current, onBack: _reloadLists),
                      if (planning.isNotEmpty) _Shelf('Plan to watch', planning, onBack: _reloadLists),
                    ],
                  );
                },
              ),
            _shelf(seasonTitle, season, onRetry: () => setState(() => season = AniList.season())),
            _shelf('Trending now', trending, onRetry: _refresh, showError: false), // the hero already shows it
            const SizedBox(height: 96), // room for the continue-watching button
          ],
        ),
      ),
    );
  }

  Widget _shelf(String title, Future<List> future, {required VoidCallback onRetry, bool showError = true}) =>
      FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return ShelfSkeleton(title: title);
          if (snap.hasError) {
            return showError
                ? _Section(title, child: ErrorState(snap.error!, compact: true, onRetry: onRetry))
                : const SizedBox.shrink();
          }
          if (snap.data!.isEmpty) {
            return _Section(
              title,
              child: const Text('Nothing here yet.', style: TextStyle(color: Colors.white54)),
            );
          }
          return _Shelf(title, snap.data!, onBack: _reloadLists);
        },
      );
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
          children: [Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), child],
        ),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.viewer, required this.onAccount, required this.onSettings});

  final Future<Map<String, dynamic>?> viewer;
  final VoidCallback onAccount, onSettings;

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
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
              ),
              IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: onSettings),
              FutureBuilder(
                future: viewer,
                builder: (context, snap) {
                  final avatar = snap.data?['avatar']?['large'] as String?;
                  return IconButton(
                    tooltip: AniList.token == null ? 'Sign in' : 'Account',
                    onPressed: onAccount,
                    icon: avatar == null
                        ? const Icon(Icons.account_circle_outlined)
                        : CircleAvatar(radius: 15, backgroundImage: NetworkImage(avatar)),
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
    required this.header,
    required this.loading,
    required this.onRetry,
    this.error,
  });

  final List items;
  final Widget header;
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
      height: MediaQuery.sizeOf(context).height * .6,
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
              child: EmptyState(icon: Icons.local_fire_department_outlined, title: 'Nothing trending right now'),
            )
          else
            PageView.builder(
              controller: controller,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (context, i) => _HeroPage(widget.items[i]),
            ),
          widget.header,
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
          _Img(media['coverImage']['extraLarge'], color: media['coverImage']['color'], alignment: Alignment.topCenter),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xAA000000), Colors.transparent, Color(0xDD0A0A0F), background],
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
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.1),
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
                    if (media['averageScore'] != null) _Score(media['averageScore']),
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
              gradient: LinearGradient(colors: [primary.withValues(alpha: .28), Colors.white.withValues(alpha: .03)]),
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
                      Text('Sign in with AniList', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      SizedBox(height: 2),
                      Text('Track what you watch automatically', style: TextStyle(color: Colors.white60, fontSize: 13)),
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
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            height: 272,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, i) => SizedBox(width: 136, child: PosterCard(items[i], onBack: onBack)),
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
    final total = media['episodes'] as int? ?? (aired == null ? null : aired - 1);
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
                  _Img(media['coverImage']['extraLarge'], color: media['coverImage']['color']),
                  if (media['averageScore'] != null)
                    Positioned(top: 8, right: 8, child: _Score(media['averageScore'], compact: true)),
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
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.25),
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
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  Future<List>? results;
  String query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String text, {bool now = false}) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < 2) return;
    _debounce = Timer(now ? Duration.zero : const Duration(milliseconds: 450), () {
      if (mounted) {
        setState(() {
          query = q;
          results = AniList.search(q);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: TextField(
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _search,
              onSubmitted: (text) => _search(text, now: true),
              decoration: _searchDecoration('Search anime'),
            ),
          ),
        ),
        body: results == null
            ? const EmptyState(
                icon: Icons.travel_explore_rounded,
                title: 'Find your next show',
                message: 'Search AniList by English or Japanese title',
              )
            : FutureBuilder(
                future: results,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return GridView.builder(
                      padding: const EdgeInsets.all(20),
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: _posterGrid,
                      itemCount: 9,
                      itemBuilder: (_, _) => const PosterSkeleton(),
                    );
                  }
                  if (snap.hasError) return ErrorState(snap.error!, onRetry: () => _search(query, now: true));
                  if (snap.data!.isEmpty) {
                    return EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No results for “$query”',
                      message: 'Check the spelling or try the other title',
                    );
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.all(20),
                    gridDelegate: _posterGrid,
                    itemCount: snap.data!.length,
                    itemBuilder: (context, i) => PosterCard(snap.data![i]),
                  );
                },
              ),
      );
}

InputDecoration _searchDecoration(String hint, {Widget? suffix}) => InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: Colors.white.withValues(alpha: .07),
      prefixIcon: const Icon(Icons.search_rounded),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
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
  late Future<Map<String, dynamic>?> record = WatchHistory.of(widget.media);
  bool dub = Settings.preferDub, expanded = false;

  Map get media => widget.media;

  @override
  void initState() {
    super.initState();
    _loadSites();
  }

  Future<void> _loadSites() async {
    try {
      final found = await sites;
      if (!mounted) return;
      setState(() => sources = found);
      final preferred = found.where((s) => s.name == Settings.preferredSource).firstOrNull ?? found.firstOrNull;
      if (preferred != null) _select(preferred);
    } catch (e) {
      sites = topSources()..ignore(); // fresh attempt for the retry button
      if (mounted) setState(() => sitesError = e);
    }
  }

  // Episodes load only for the chosen site, so a Cloudflare prompt appears only when that site needs one.
  void _select(Source s) => setState(() {
        source = s;
        episodes = withCloudflare(context, () => loadEpisodes(s, media));
      });

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
    final accent = _hex(media['coverImage']['color']) ?? Theme.of(context).colorScheme.primary;
    final entry = media['mediaListEntry'] as Map?;
    final progress = entry?['progress'] as int? ?? 0;
    final total = media['episodes'] as int?;
    final meta = [
      media['format'],
      media['seasonYear'],
      if (total != null) '$total eps',
      (media['status'] as String?)?.replaceAll('_', ' '),
    ].whereType<Object>().join('  ·  ');
    final description = (media['description'] as String? ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();

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
                  _Img(media['bannerImage'] ?? media['coverImage']['extraLarge'], color: media['coverImage']['color']),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x88000000), Colors.transparent, background],
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
                        boxShadow: [BoxShadow(color: accent.withValues(alpha: .4), blurRadius: 28, offset: const Offset(0, 10))],
                      ),
                      child: _Img(media['coverImage']['extraLarge'], color: media['coverImage']['color']),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(titleOf(media), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.15)),
                          const SizedBox(height: 6),
                          Text(meta, style: const TextStyle(fontSize: 11, letterSpacing: 1, color: Colors.white54)),
                          const SizedBox(height: 10),
                          if (media['averageScore'] != null) _Score(media['averageScore']),
                        ],
                      ),
                    ),
                  ],
                ),
                if (AniList.token != null) ...[
                  const SizedBox(height: 20),
                  _ProgressCard(progress: progress, total: total, status: entry?['status'], accent: accent),
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
                        style: const TextStyle(color: Colors.white70, height: 1.5),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    const Text('Episodes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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

  /// Resume the saved spot for this show, else continue after the AniList progress on the selected source.
  Widget _continueButton(int progress) => FutureBuilder(
        future: record,
        builder: (context, saved) {
          final r = saved.data;
          if (r != null) {
            final at = Duration(milliseconds: r['position'] as int? ?? 0);
            final resumes = Settings.resume && at > Duration.zero;
            return ContinueFab(
              title: '${resumes ? 'Resume' : 'Continue'} EP ${epNumber(r['episode'])}',
              subtitle: '${r['source']}${resumes ? ' · ${formatDuration(at)}' : ''}',
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
                title: progress == 0 ? 'Start watching' : 'Continue EP ${epNumber(list[next].number)}',
                subtitle: current.name,
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen(media: media, source: current, episodes: list, index: next, dub: dub),
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
      return const Row(
        children: [
          Skeleton(width: 96, height: 34, radius: 17),
          SizedBox(width: 8),
          Skeleton(width: 96, height: 34, radius: 17),
          SizedBox(width: 8),
          Skeleton(width: 96, height: 34, radius: 17),
        ],
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
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (i, s) in sources!.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('#${i + 1}  ${s.name}'),
                selected: s == source,
                onSelected: (_) => _select(s),
              ),
            ),
        ],
      ),
    );
  }

  Widget _episodeList(int progress) {
    final current = source;
    if (episodes == null || current == null) return const SliverToBoxAdapter();
    return FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SliverList.builder(itemCount: 6, itemBuilder: (_, _) => const EpisodeSkeleton());
        }
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ErrorState(snap.error!, compact: true, onRetry: () => _select(current)),
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
        return SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, i) => _EpisodeTile(
            list[i],
            watched: list[i].number <= progress,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(media: media, source: current, episodes: list, index: i, dub: dub),
                ),
              );
              if (mounted) setState(() => record = WatchHistory.of(media)); // progress and resume point changed
            },
          ),
        );
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

  Future<List<SearchResult>> _run() => withCloudflare(context, () => widget.source.search(controller.text.trim()));

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
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
                        suffix: IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _retry),
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
                      return ListView.builder(controller: scroll, itemCount: 6, itemBuilder: (_, _) => const _ResultSkeleton());
                    }
                    if (snap.hasError) {
                      return ListView(controller: scroll, children: [ErrorState(snap.error!, onRetry: _retry)]);
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
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(width: 44, height: 62, child: _Img(result.image)),
                          ),
                          title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: result.info == null || result.info!.isEmpty ? null : Text(result.info!),
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
                children: [Skeleton(height: 14, radius: 6), SizedBox(height: 8), Skeleton(height: 11, width: 120, radius: 6)],
              ),
            ),
          ],
        ),
      );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress, required this.total, required this.status, required this.accent});

  final int progress;
  final int? total;
  final String? status;
  final Color accent;

  static const _labels = {
    'CURRENT': 'Watching',
    'PLANNING': 'Planning',
    'COMPLETED': 'Completed',
    'DROPPED': 'Dropped',
    'PAUSED': 'Paused',
    'REPEATING': 'Rewatching',
  };

  @override
  Widget build(BuildContext context) {
    final total = this.total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: [accent.withValues(alpha: .22), Colors.white.withValues(alpha: .03)]),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_rounded, size: 18, color: accent),
              const SizedBox(width: 8),
              Text(_labels[status] ?? 'Not in your list', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$progress / ${total ?? '?'}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == null || total == 0 ? 0 : (progress / total).clamp(0.0, 1.0).toDouble(),
              minHeight: 6,
              color: accent,
              backgroundColor: Colors.white10,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile(this.episode, {required this.watched, required this.onTap});

  final Episode episode;
  final bool watched;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = episode.thumbnail;
    final title = episode.title;
    final overview = episode.overview;
    return InkWell(
      onTap: onTap,
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
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white24),
                        ),
                      ),
                    ),
                    if (thumbnail != null) _Img(thumbnail, transparent: true),
                    if (watched)
                      const ColoredBox(
                        color: Color(0x99000000),
                        child: Center(child: Icon(Icons.check_circle_rounded, color: Colors.white)),
                      )
                    else if (thumbnail != null)
                      Center(child: Icon(Icons.play_circle_fill_rounded, size: 30, color: Colors.white.withValues(alpha: .9))),
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
                    style: TextStyle(fontWeight: FontWeight.w700, color: watched ? Colors.white54 : Colors.white),
                  ),
                  if (title != null)
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  if (overview != null)
                    Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Colors.white38, height: 1.3),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Continue watching ─────────────────────────────

/// Reopens the player where a [WatchHistory] record left off.
Future<void> resumeWatching(BuildContext context, Map<String, dynamic> record, {List<Episode>? loaded}) async {
  final media = record['media'] as Map;
  final source = (await sites).where((s) => s.name == record['source']).firstOrNull;
  if (source == null) throw Exception('${record['source']} is no longer one of the top sites');
  if (!context.mounted) return;
  final episodes = loaded ?? await withCloudflare<List<Episode>>(context, () => loadEpisodes(source, media));
  final index = episodes.indexWhere((e) => e.number == record['episode']);
  if (index == -1) throw Exception('Episode ${epNumber(record['episode'])} is not on ${source.name} yet');
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        media: media,
        source: source,
        episodes: episodes,
        index: index,
        dub: record['dub'] == true,
        start: Settings.resume ? Duration(milliseconds: record['position'] as int? ?? 0) : null,
      ),
    ),
  );
}

class ContinueFab extends StatefulWidget {
  const ContinueFab({super.key, required this.title, required this.subtitle, required this.onPressed});

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
  Widget build(BuildContext context) => FloatingActionButton.extended(
        onPressed: busy ? null : _run,
        icon: busy
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : const Icon(Icons.play_arrow_rounded, size: 28),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
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
  const _Img(this.url, {this.color, this.alignment = Alignment.center, this.transparent = false});

  final String? url;
  final String? color;
  final Alignment alignment;
  final bool transparent; // draw over a placeholder instead of a filled box

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return ColoredBox(
      color: transparent ? Colors.transparent : _hex(color)?.withValues(alpha: .3) ?? const Color(0xFF1A1A24),
      child: url == null
          ? null
          : Image.network(
              url,
              fit: BoxFit.cover,
              alignment: alignment,
              frameBuilder: (context, child, frame, sync) => sync
                  ? child
                  : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 300), child: child),
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
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 3 : 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, size: compact ? 12 : 16, color: const Color(0xFFFFC857)),
            const SizedBox(width: 3),
            Text('$score%', style: TextStyle(fontSize: compact ? 11 : 13, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
