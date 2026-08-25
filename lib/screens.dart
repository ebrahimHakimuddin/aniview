import 'dart:async';

import 'package:flutter/material.dart';

import 'anilist.dart';
import 'cloudflare.dart';
import 'player.dart';
import 'sources.dart';

const background = Color(0xFF0A0A0F);

Future<void> openDetails(BuildContext context, Map media, {VoidCallback? onBack}) async {
  await Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(media)));
  onBack?.call();
}

Color? _hex(String? hex) => hex == null || hex.length != 7 ? null : Color(int.parse('FF${hex.substring(1)}', radix: 16));

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

  void _reloadLists() => setState(() => lists = AniList.lists());

  Future<void> _refresh() async {
    setState(() {
      viewer = AniList.viewer();
      lists = AniList.lists();
      trending = AniList.trending();
    });
    try {
      await Future.wait([lists, trending]);
    } catch (_) {}
  }

  Future<void> _account() async {
    if (AniList.token != null) {
      final logout = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: const Color(0xFF14141C),
        builder: (context) => SafeArea(
          child: FutureBuilder(
            future: viewer,
            builder: (context, snap) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: snap.data?['avatar']?['large'] == null
                      ? const Icon(Icons.account_circle_rounded)
                      : CircleAvatar(backgroundImage: NetworkImage(snap.data!['avatar']['large'])),
                  title: Text(snap.data?['name'] ?? 'AniList'),
                  subtitle: const Text('Signed in with AniList'),
                ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded),
                  title: const Text('Sign out'),
                  onTap: () => Navigator.pop(context, true),
                ),
              ],
            ),
          ),
        ),
      );
      if (logout != true) return;
      await AniList.logout();
    } else if (AniList.clientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Build with --dart-define=ANILIST_CLIENT_ID=<your AniList client id>')),
      );
      return;
    } else {
      try {
        await AniList.login();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
        return;
      }
    }
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: background,
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              FutureBuilder(
                future: trending,
                builder: (context, snap) => _Hero(
                  items: snap.data?.take(6).toList() ?? const [],
                  error: snap.error,
                  header: _TopBar(viewer: viewer, onAccount: _account),
                ),
              ),
              FutureBuilder(
                future: lists,
                builder: (context, snap) {
                  final data = snap.data ?? const <String, List>{};
                  return Column(
                    children: [
                      if (AniList.token == null)
                        _SignInCard(onTap: _account)
                      else if (snap.hasError)
                        _Notice('Could not load your AniList: ${snap.error}'),
                      if (data['CURRENT']?.isNotEmpty ?? false)
                        _Shelf('Continue watching', data['CURRENT']!, onBack: _reloadLists),
                      if (data['PLANNING']?.isNotEmpty ?? false)
                        _Shelf('Plan to watch', data['PLANNING']!, onBack: _reloadLists),
                    ],
                  );
                },
              ),
              FutureBuilder(
                future: trending,
                builder: (context, snap) =>
                    snap.hasData ? _Shelf('Trending now', snap.data!, onBack: _reloadLists) : const SizedBox(),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.viewer, required this.onAccount});

  final Future<Map<String, dynamic>?> viewer;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
          child: Row(
            children: [
              Text(
                'ANIME',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 5,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
              ),
              FutureBuilder(
                future: viewer,
                builder: (context, snap) {
                  final avatar = snap.data?['avatar']?['large'] as String?;
                  return IconButton(
                    tooltip: 'Account',
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
  const _Hero({required this.items, required this.header, this.error});

  final List items;
  final Widget header;
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
          if (widget.items.isEmpty)
            Center(
              child: widget.error == null
                  ? const CircularProgressIndicator()
                  : _Empty(Icons.cloud_off_rounded, 'AniList is unavailable right now\n${widget.error}'),
            )
          else
            PageView.builder(
              controller: controller,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (context, i) => _HeroPage(widget.items[i]),
            ),
          widget.header,
          if (widget.items.length > 1)
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
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String text, {bool now = false}) {
    _debounce?.cancel();
    if (text.trim().length < 2) return;
    _debounce = Timer(now ? Duration.zero : const Duration(milliseconds: 450), () {
      if (mounted) setState(() => results = AniList.search(text.trim()));
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
              decoration: InputDecoration(
                hintText: 'Search anime',
                isDense: true,
                filled: true,
                fillColor: Colors.white.withValues(alpha: .07),
                prefixIcon: const Icon(Icons.search_rounded),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
              ),
            ),
          ),
        ),
        body: results == null
            ? const _Empty(Icons.travel_explore_rounded, 'Find something to watch')
            : FutureBuilder(
                future: results,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) return _Empty(Icons.error_outline_rounded, '${snap.error}');
                  if (snap.data!.isEmpty) return const _Empty(Icons.search_off_rounded, 'No results');
                  return GridView.builder(
                    padding: const EdgeInsets.all(20),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 150,
                      childAspectRatio: .46,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: snap.data!.length,
                    itemBuilder: (context, i) => PosterCard(snap.data![i]),
                  );
                },
              ),
      );
}

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
  bool dub = false, expanded = false;

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
      if (found.isNotEmpty) _select(found.first);
    } catch (e) {
      sites = topSources()..ignore(); // fresh attempt for the retry button
      if (mounted) setState(() => sitesError = e);
    }
  }

  // Episodes load only for the chosen site, so a Cloudflare prompt appears only when that site needs one.
  void _select(Source s) => setState(() {
        source = s;
        episodes = withCloudflare(context, () => s.episodes(media));
      });

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
                const SizedBox(height: 8),
              ],
            ),
          ),
          _episodeList(progress),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _sourcePicker() {
    if (sitesError != null) {
      return _Notice(
        'Could not load sources from everythingmoe: $sitesError',
        action: TextButton(
          onPressed: () {
            setState(() => sitesError = null);
            _loadSites();
          },
          child: const Text('Retry'),
        ),
      );
    }
    if (sources == null) return const LinearProgressIndicator(minHeight: 2);
    if (sources!.isEmpty) return const _Notice('None of the top sites on everythingmoe are supported yet.');
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
    if (episodes == null) return const SliverToBoxAdapter();
    return FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          );
        }
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _Notice(
                '${snap.error}',
                action: TextButton(onPressed: () => _select(source!), child: const Text('Retry')),
              ),
            ),
          );
        }
        final list = snap.data!;
        if (list.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _Notice('${titleOf(media)} was not found on ${source!.name}. Try another source.'),
            ),
          );
        }
        final current = source!;
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
              if (mounted) setState(() {}); // progress may have changed
            },
          ),
        );
      },
    );
  }
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 128,
                height: 72,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (thumbnail == null)
                      ColoredBox(
                        color: Colors.white.withValues(alpha: .05),
                        child: Center(
                          child: Text(
                            epNumber(episode.number),
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white24),
                          ),
                        ),
                      )
                    else ...[
                      _Img(thumbnail),
                      if (!watched)
                        Center(child: Icon(Icons.play_circle_fill_rounded, size: 30, color: Colors.white.withValues(alpha: .9))),
                    ],
                    if (watched)
                      const ColoredBox(
                        color: Color(0x99000000),
                        child: Center(child: Icon(Icons.check_circle_rounded, color: Colors.white)),
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
                    style: TextStyle(fontWeight: FontWeight.w700, color: watched ? Colors.white54 : Colors.white),
                  ),
                  if (title != null)
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Shared bits ─────────────────────────────

class _Img extends StatelessWidget {
  const _Img(this.url, {this.color, this.alignment = Alignment.center});

  final String? url;
  final String? color;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return ColoredBox(
      color: _hex(color)?.withValues(alpha: .3) ?? const Color(0xFF1A1A24),
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

class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, size: 18, color: Colors.white38),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13))),
            ?action,
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: Colors.white24),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
}
