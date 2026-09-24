import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'cloudflare.dart';
import 'downloads.dart';
import 'history.dart';
import 'player.dart';
import 'search.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';

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

bool _playerOpening = false;

/// Every way into the player comes through here, so a second tap before the first player shows can't open
/// another one on top (two players, two soundtracks).
Future<void> _openPlayer(
  BuildContext context, {
  required Map media,
  required Source? source,
  String? sourceName,
  required List<Episode> episodes,
  required int index,
  required bool dub,
}) async {
  if (_playerOpening) return;
  _playerOpening = true;
  try {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          media: media,
          source: source,
          sourceName: sourceName,
          episodes: episodes,
          index: index,
          dub: dub,
        ),
      ),
    );
  } finally {
    _playerOpening = false;
  }
}

/// Reopens the player where a [WatchHistory] record left off, from downloads when the site can't be reached.
Future<void> resumeWatching(
  BuildContext context,
  WatchRecord record, {
  List<Episode>? loaded,
}) async {
  final media = record.media;
  final number = record.episode;
  // What plays with the site out of reach (see [Downloads.toPlay]).
  final downloaded = [
    for (final d in Downloads.instance.forMedia(media)) d.episode,
  ];
  Source? source;
  var episodes = loaded ?? const <Episode>[];
  try {
    source = await Sites.named(record.source);
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
          ? '${record.source} is no longer one of the top sites'
          : 'Episode ${epNumber(number)} is not on ${source.name} yet',
    );
  }
  if (!context.mounted) return;
  await _openPlayer(
    context,
    media: media,
    source: source,
    sourceName: record.source,
    episodes: episodes,
    index: index,
    dub: record.dub,
  );
}

/// The screen's main action, with a spinner while it gets going: a full-width button on a phone's details page,
/// an extended FAB on home, a regular button in a TV action row.
class PlayAction extends StatefulWidget {
  const PlayAction({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.fab = false,
    this.autofocus = false,
  });

  final String title, subtitle;
  final Future<void> Function() onPressed;
  final bool fab, autofocus;

  @override
  State<PlayAction> createState() => _PlayActionState();
}

class _PlayActionState extends State<PlayAction> {
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
  Widget build(BuildContext context) {
    final icon = busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        : const Icon(Icons.play_arrow_rounded, size: 28);
    final label = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
          widget.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
        ),
      ],
    );
    if (widget.fab) {
      return FloatingActionButton.extended(
        tooltip: '${widget.title} · ${widget.subtitle}',
        onPressed: busy ? null : _run,
        icon: icon,
        label: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * .55,
          ),
          child: label,
        ),
      );
    }
    return FilledButton.icon(
      autofocus: widget.autofocus,
      style: FilledButton.styleFrom(
        minimumSize: Size(isTv ? 0 : double.infinity, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      onPressed: busy ? null : _run,
      icon: icon,
      label: label,
    );
  }
}

const _listLabels = {
  'CURRENT': 'Watching',
  'PLANNING': 'Planning',
  'COMPLETED': 'Completed',
  'PAUSED': 'Paused',
  'DROPPED': 'Dropped',
  'REPEATING': 'Rewatching',
};

/// A show: its art and details, the main play action, your AniList entry, and its episodes on the chosen site.
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
  late Future<WatchRecord?> record = _ids.then(
    (_) => WatchHistory.of(widget.media),
  );
  late final relations = _ids.then((_) => Tracker.relations(widget.media));
  late final cachedSeason = _ids.then(
    (_) => Downloads.instance.season(widget.media),
  );
  bool dub = Settings.preferDub,
      expanded = false,
      aboutFocused = false,
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

  Future<void> _loadSites() async {
    try {
      await _ids;
      final found = await Sites.all();
      if (!mounted) return;
      setState(() => sources = found);
      if (Sites.preferred(found) case final preferred?) _select(preferred);
    } catch (e) {
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

  void _reloadRecord() {
    if (mounted) setState(() => record = WatchHistory.of(media));
  }

  /// Long-press on an episode: watched state and its download.
  Future<void> _episodeActions(
    Episode episode, {
    required bool watched,
    required Source? site,
    required List<Episode> season,
  }) async {
    if (!Settings.episodeTipSeen) {
      setState(() => Settings.episodeTipSeen = true);
    }
    final download = Downloads.instance.entry(media, episode.number, dub);
    final action = await showSheet<VoidCallback>(
      context,
      (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sheetTitle(
              context,
              'Episode ${epNumber(episode.number)}',
              subtitle: episode.title,
            ),
            ListTile(
              autofocus: isTv,
              leading: Icon(
                watched ? Icons.remove_done_rounded : Icons.done_all_rounded,
              ),
              title: Text(
                watched ? 'Mark as unwatched' : 'Mark watched up to here',
              ),
              onTap: () => Navigator.pop(
                context,
                () => _markWatched(
                  watched
                      ? EpisodePlan.progressUnwatching(episode)
                      : EpisodePlan.progressWatching(episode),
                ),
              ),
            ),
            if (site != null && download == null)
              ListTile(
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
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete download'),
                onTap: () => Navigator.pop(
                  context,
                  () => confirmDeleteDownload(this.context, download!),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    action?.call();
  }

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
    final result =
        await showSheet<({String status, int progress, bool remove})>(
          context,
          scrollControlled: true,
          (_) => _EntrySheet(
            status: show.listStatus,
            progress: show.progress,
            total: show.episodes,
            inList: show.inList,
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
                ? 'Saved as ${_listLabels[result.status]} · ${result.progress} watched'
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
    final picked = await showSheet<SearchResult>(
      context,
      scrollControlled: true,
      (_) => _MatchSheet(source: current, query: titleOf(media)),
    );
    if (picked == null || !mounted) return;
    await setMatch(current, media, picked.id);
    if (!mounted) return;
    _select(current);
    showSuccess(context, 'Using “${picked.title}” on ${current.name}');
  }

  // ───────────────────────────── Pieces ─────────────────────────────

  Show get show => Show(media);
  int get _progress => show.progress;

  /// The main button, as [EpisodePlan.nextUp] decides: back to the saved spot, else the next unwatched episode
  /// on the chosen site.
  Widget _playAction() => FutureBuilder(
    future: record,
    builder: (context, saved) => FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        final list = snap.data;
        return switch (EpisodePlan.nextUp(saved.data, list, _progress)) {
          ResumeSaved(:final record, :final midway) => PlayAction(
            autofocus: isTv,
            title:
                '${midway ? 'Resume' : 'Continue'} Episode ${epNumber(record.episode)}',
            subtitle:
                '${record.source}${midway ? ' · from ${formatDuration(record.position)}' : ''}',
            onPressed: () async {
              final loaded = record.source == source?.name
                  ? await episodes
                  : null;
              if (!context.mounted) return;
              await resumeWatching(context, record, loaded: loaded);
              _reloadRecord();
            },
          ),
          StartEpisode(:final episode, :final first) => PlayAction(
            autofocus: isTv,
            title:
                '${first ? 'Play' : 'Continue'} Episode ${epNumber(episode.number)}',
            subtitle: '${source!.name} · ${dub ? 'Dub' : 'Sub'}',
            onPressed: () async {
              await _openPlayer(
                context,
                media: media,
                source: source,
                episodes: list!,
                index: list.indexOf(episode),
                dub: dub,
              );
              _reloadRecord();
            },
          ),
          // Holds the button's place while things load.
          null =>
            snap.connectionState == ConnectionState.done ||
                    saved.connectionState != ConnectionState.done
                ? const SizedBox.shrink()
                : SizedBox(
                    width: isTv ? 220 : double.infinity,
                    child: const Skeleton(height: 56, radius: 28),
                  ),
        };
      },
    ),
  );

  Widget get _audio => SegmentedButton<bool>(
    segments: const [
      ButtonSegment(value: false, label: Text('Sub')),
      ButtonSegment(value: true, label: Text('Dub')),
    ],
    selected: {dub},
    showSelectedIcon: false,
    onSelectionChanged: (s) => setState(() => dub = s.first),
  );

  /// The site to watch on, as a menu button ("#1 Anikoto").
  Widget _sourceMenu() {
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
    final all = sources;
    if (all == null) return const Skeleton(width: 160, height: 40, radius: 20);
    if (all.isEmpty) {
      return Text(
        "None of everythingmoe's top sites are supported yet",
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: () async {
        final picked = await pickOne(context, 'Watch on', {
          for (final (i, s) in all.indexed) s: '#${i + 1}  ${s.label}',
        }, source);
        if (picked != null && picked != source && mounted) _select(picked);
      },
      icon: const Icon(Icons.dns_outlined, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            source == null
                ? 'Pick a site'
                : '#${all.indexOf(source!) + 1}  ${source!.label}',
          ),
          const Icon(Icons.arrow_drop_down_rounded),
        ],
      ),
    );
  }

  /// Download episodes, mark the season watched, fix the site's match.
  Widget _moreMenu() => FutureBuilder(
    future: episodes,
    builder: (context, snap) {
      final list = snap.data, site = source;
      final hasEpisodes = list != null && list.isNotEmpty;
      final actions = <(IconData, String, VoidCallback)>[
        if (hasEpisodes && site != null)
          (
            Icons.download_rounded,
            'Download episodes…',
            () => _downloadSeason(site, list, _progress),
          ),
        if (hasEpisodes && Tracker.signedIn)
          (
            Icons.done_all_rounded,
            'Mark season watched',
            () => _markWatched(
              list.fold(0, (n, e) => e.number > n ? e.number.toInt() : n),
            ),
          ),
        if (site != null)
          (
            Icons.swap_horiz_rounded,
            'Wrong show? Pick the right one',
            _fixMatch,
          ),
      ];
      // An empty menu would open as a blank box.
      if (actions.isEmpty) return const SizedBox.shrink();
      return PopupMenuButton<VoidCallback>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          for (final (icon, label, action) in actions)
            PopupMenuItem(
              value: action,
              child: ListTile(leading: Icon(icon), title: Text(label)),
            ),
        ],
      );
    },
  );

  Widget _genres() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final genre in show.genres)
        ActionChip(
          label: Text('$genre'),
          tooltip: 'Browse $genre',
          onPressed: () =>
              openSearch(context, SearchFilters(genres: {'$genre'})),
        ),
    ],
  );

  /// The synopsis, a few lines until tapped; focusable so a remote can open it too.
  /// Its outline is drawn around the text as laid out, so it grows with it (an ink highlight kept the size it
  /// had before the text expanded).
  Widget _about(String description) => InkWell(
    borderRadius: BorderRadius.circular(12),
    focusColor: Colors.transparent,
    onFocusChange: (v) => setState(() => aboutFocused = v),
    onTap: () => setState(() => expanded = !expanded),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: aboutFocused
            ? scheme.onSurface.withValues(alpha: .08)
            : Colors.transparent,
        border: Border.all(
          color: aboutFocused ? scheme.onSurface : Colors.transparent,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          description,
          maxLines: expanded ? null : 3,
          overflow: expanded ? null : TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
      ),
    ),
  );

  Widget _related() => FutureBuilder(
    future: relations,
    builder: (context, snap) {
      final found = snap.data ?? const <(String, Map)>[];
      if (found.isEmpty) return const SizedBox.shrink();
      return MediaRow(
        'Related',
        [for (final (_, m) in found) m],
        subtitles: [
          for (final (type, _) in found)
            type == 'PREQUEL' ? 'Prequel' : 'Sequel',
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => isTv ? _tv() : _phone();

  Widget _phone() {
    final text = Theme.of(context).textTheme;
    final total = show.episodes;
    final airing = airingLabel(media);
    final score = show.score;
    final description = plainText(show.description);
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      // Play sits in the thumb zone, always in reach while the episodes scroll.
      bottomNavigationBar: Material(
        color: scheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 12, side, 12),
            child: _playAction(),
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            stretch: true,
            expandedHeight: width * 9 / 16,
            actions: [_moreMenu()],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Artwork(
                    show.backdrop,
                    color: show.color,
                    full: show.hasBanner,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: .55),
                          Colors.transparent,
                          scheme.surface,
                        ],
                        stops: const [0, .45, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: SliverList.list(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 96,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: Artwork(show.cover, color: show.color),
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
                            style: text.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              mediaMeta(media, genres: 0),
                              (media['status'] as String?)
                                  ?.replaceAll('_', ' ')
                                  .toLowerCase(),
                            ].whereType<String>().join(' · '),
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (score != null) Pill.score(score),
                              if (airing != null)
                                Pill(
                                  'Next $airing',
                                  icon: Icons.schedule_rounded,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (Tracker.signedIn) ...[
                  const SizedBox(height: 24),
                  _ListEntry(
                    progress: _progress,
                    total: total,
                    status: show.listStatus,
                    onTap: _editEntry,
                  ),
                ],
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _about(description),
                ],
                if (show.genres.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _genres(),
                ],
              ],
            ),
          ),
          SliverToBoxAdapter(child: _related()),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Episodes', style: text.titleLarge)),
                      _audio,
                    ],
                  ),
                  const SizedBox(height: 12),
                  _sourceMenu(),
                ],
              ),
            ),
          ),
          _episodeList(),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  /// TV: the show's art at the top right under a cinematic scrim, its details and a row of actions (play first)
  /// on the left, then the episodes as a row of stills, related shows and genres.
  Widget _tv() {
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final total = show.episodes;
    final airing = airingLabel(media);
    final score = show.score;
    final description = plainText(show.description);
    return Scaffold(
      body: Stack(
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
                      stops: const [0, .4, .75],
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
                      stops: const [.4, 1],
                    ),
                  ),
                ),
              ],
            ),
          ),
          CustomScrollView(
            clipBehavior: Clip.none,
            slivers: [
              SliverToBoxAdapter(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: size.height * .62),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      tvMargin,
                      24,
                      tvMargin,
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: size.width * .5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                titleOf(media),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.headlineLarge?.copyWith(
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
                                    Pill(
                                      'Next $airing',
                                      icon: Icons.schedule_rounded,
                                    ),
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
                                const SizedBox(height: 12),
                                _about(description),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        TvRow(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _playAction(),
                              _audio,
                              _sourceMenu(),
                              if (Tracker.signedIn)
                                FilledButton.tonalIcon(
                                  onPressed: _editEntry,
                                  icon: Icon(
                                    !show.inList
                                        ? Icons.bookmark_add_outlined
                                        : Icons.bookmark_rounded,
                                  ),
                                  label: Text(
                                    '${_listLabels[show.listStatus] ?? 'Add to list'} · $_progress/${total ?? '?'}',
                                  ),
                                ),
                              _moreMenu(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _episodeList(),
              SliverToBoxAdapter(child: _related()),
              if (show.genres.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      tvMargin,
                      24,
                      tvMargin,
                      24,
                    ),
                    child: _genres(),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── Episodes ─────────────────────────────

  Widget _episodeList() {
    final current = source;
    if (episodes == null || current == null) {
      return (sitesError != null ? _offlineList() : null) ??
          const SliverToBoxAdapter();
    }
    return FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SliverToBoxAdapter(child: _EpisodesSkeleton());
        }
        if (snap.hasError) {
          return _offlineList() ??
              SliverToBoxAdapter(
                child: ErrorState(
                  snap.error!,
                  compact: true,
                  onRetry: () => _select(current),
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
              message: 'The site may list it under another name. Pick it manually or try another site.',
              action: FilledButton.tonalIcon(
                onPressed: _fixMatch,
                icon: const Icon(Icons.manage_search_rounded),
                label: const Text('Find it manually'),
              ),
            ),
          );
        }
        return _episodeSliver(list, current);
      },
    );
  }

  /// Downloaded episodes, shown when the site can't be reached.
  Widget? _offlineList() {
    final downloaded = [
      for (final d in Downloads.instance.forMedia(media)) d.episode,
    ];
    if (downloaded.isEmpty) return null;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: side, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    "Can't reach the site, only downloaded episodes play",
                  ),
                ),
              ],
            ),
          ),
        ),
        FutureBuilder(
          future: cachedSeason,
          builder: (context, snap) =>
              _episodeSliver(snap.data ?? downloaded, null),
        ),
      ],
    );
  }

  /// [site] is null offline, when only downloaded episodes play. Shown [_pageSize] at a time; the player always
  /// gets them in order.
  Widget _episodeSliver(List<Episode> list, Source? site) {
    final playable = site != null
        ? list
        : [
            for (final e in list)
              if (Downloads.instance.toPlay(
                    media,
                    e.number,
                    dub: dub,
                    online: false,
                  ) !=
                  null)
                e,
          ];
    return FutureBuilder(
      future: record,
      builder: (context, saved) {
        final plan = EpisodePlan(
          list,
          progress: _progress,
          record: saved.data,
          newestFirst: newestFirst,
          page: page,
          pageSize: _pageSize,
        );
        final shown = plan.shown;
        Widget tile(BuildContext _, int i) =>
            _episode(plan.shown[i], plan, list, playable, site);
        return SliverMainAxisGroup(
          slivers: [
            if (isTv)
              const SliverToBoxAdapter(child: SectionHeader('Episodes')),
            SliverToBoxAdapter(child: _episodeControls(list, plan)),
            if (isTv)
              SliverToBoxAdapter(
                child: ScrollAnchor(
                  child: _EpisodeRow(
                    key: ValueKey((plan.page, newestFirst, dub)),
                    count: shown.length,
                    start: plan.upNext == null
                        ? 0
                        : shown.indexOf(plan.upNext!),
                    itemBuilder: tile,
                  ),
                ),
              )
            else
              SliverList.builder(itemCount: shown.length, itemBuilder: tile),
          ],
        );
      },
    );
  }

  /// The long-press tip until it's used or dismissed, the order, and pages for long shows.
  Widget _episodeControls(List<Episode> list, EpisodePlan plan) {
    final pages = plan.pages;
    return Padding(
      padding: EdgeInsets.fromLTRB(side - 8, 0, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!Settings.episodeTipSeen && list.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${isTv ? 'Hold OK on' : 'Long-press'} an episode to mark it watched or manage its download',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
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
          if (list.length > 1)
            Row(
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
                        padding: EdgeInsets.only(right: side),
                        itemCount: pages.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => ChoiceChip(
                          label: Text(
                            '${epNumber(pages[i].first.number)}–${epNumber(pages[i].last.number)}',
                          ),
                          selected: i == plan.page,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onSelected: (_) => setState(() => page = i),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _episode(
    Episode episode,
    EpisodePlan plan,
    List<Episode> list,
    List<Episode> playable,
    Source? site,
  ) {
    final watched = plan.watched(episode);
    final saved = site != null || playable.contains(episode);
    return _EpisodeTile(
      episode,
      watched: watched,
      upNext: episode == plan.upNext,
      resumedPart: plan.resumedPart(episode),
      onLongPress: () =>
          _episodeActions(episode, watched: watched, site: site, season: list),
      trailing: site == null
          ? saved
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.download_done_rounded,
                      color: scheme.onSurfaceVariant,
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
        await _openPlayer(
          context,
          media: media,
          source: site,
          sourceName:
              site?.name ??
              Downloads.instance.forMedia(media).firstOrNull?.source,
          episodes: playable,
          index: playable.indexOf(episode),
          dub: dub,
        );
        _reloadRecord(); // progress and resume point changed
      },
    );
  }
}

/// Your AniList entry for the show: status and episodes watched, with a bar; tap to edit.
class _ListEntry extends StatelessWidget {
  const _ListEntry({
    required this.progress,
    required this.total,
    required this.status,
    required this.onTap,
  });

  final int progress;
  final int? total;
  final String? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final total = this.total;
    final text = Theme.of(context).textTheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    status == null
                        ? Icons.bookmark_add_outlined
                        : Icons.bookmark_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _listLabels[status] ?? 'Add to your list',
                      style: text.titleSmall,
                    ),
                  ),
                  Text('$progress / ${total ?? '?'}', style: text.titleSmall),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: total == null || total == 0
                    ? 0
                    : (progress / total).clamp(0.0, 1.0).toDouble(),
                borderRadius: BorderRadius.circular(4),
                minHeight: 4,
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
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.inList ? 'Update your list' : 'Add to your list',
              style: text.titleLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(:key, :value) in _listLabels.entries)
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
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text('Episodes watched', style: text.titleSmall),
                ),
                IconButton.filledTonal(
                  tooltip: 'One fewer',
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
                    style: text.titleMedium,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'One more',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: total == null || progress < total
                      ? () => _setProgress(progress + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                if (widget.inList)
                  TextButton.icon(
                    onPressed: () => _done(remove: true),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove'),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                  ),
                const Spacer(),
                FilledButton(
                  autofocus: isTv,
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
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * (isTv ? .75 : .85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sheetTitle(
            context,
            'Pick the show on ${widget.source.name}',
            subtitle: 'Your choice is remembered for this show.',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _retry(),
              decoration: InputDecoration(
                hintText: 'Search ${widget.source.name}',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: _retry,
                ),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: results,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return ErrorState(snap.error!, onRetry: _retry);
                }
                if (snap.data!.isEmpty) {
                  return const EmptyState(
                    compact: true,
                    icon: Icons.search_off_rounded,
                    title: 'No shows found',
                    message: 'Try a shorter or alternative title',
                  );
                }
                return ListView.builder(
                  itemCount: snap.data!.length,
                  itemBuilder: (context, i) {
                    final result = snap.data![i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 4,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 62,
                          child: Artwork(result.image),
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

class _EpisodesSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (isTv) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(tvMargin, 8, 0, 24),
        child: Row(
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(right: gutter),
                child: const Skeleton(
                  width: _EpisodeRow.width,
                  height: _EpisodeRow.width * 9 / 16,
                ),
              ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: side, vertical: 8),
            child: const Row(
              children: [
                Skeleton(width: 128, height: 72),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Skeleton(height: 14, width: 110, radius: 6),
                      SizedBox(height: 8),
                      Skeleton(height: 12, radius: 6),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// An episode: a still (dimmed once watched, with the resume point along its bottom edge), its number, title and
/// synopsis. A list row on phones, a card in a row of stills on TV.
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile(
    this.episode, {
    required this.watched,
    required this.onTap,
    this.upNext = false,
    this.resumedPart,
    this.onLongPress,
    this.trailing,
  });

  final Episode episode;
  final bool watched, upNext;

  /// How far into this episode the saved resume point is, 0–1.
  final double? resumedPart;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  String? get _badge => !upNext
      ? null
      : resumedPart != null
      ? 'Resume'
      : 'Up next';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final title = Row(
      children: [
        Flexible(
          child: Text(
            'Episode ${epNumber(episode.number)}',
            style: text.titleSmall?.copyWith(
              color: watched ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ),
        if (_badge case final badge?) ...[
          const SizedBox(width: 8),
          Text(
            badge.toUpperCase(),
            style: text.labelSmall?.copyWith(
              color: scheme.primary,
              letterSpacing: .8,
            ),
          ),
        ],
      ],
    );
    final name = episode.title;
    if (isTv) {
      return SizedBox(
        width: _EpisodeRow.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FocusCard(
              onTap: onTap,
              onLongPress: onLongPress,
              semanticLabel: 'Episode ${epNumber(episode.number)}',
              child: AspectRatio(aspectRatio: 16 / 9, child: _still()),
            ),
            const SizedBox(height: 8),
            title,
            if (name != null)
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      );
    }
    final overview = episode.overview;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            },
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 8, trailing == null ? side : 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(aspectRatio: 16 / 9, child: _still()),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (name != null)
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: watched
                            ? scheme.onSurfaceVariant.withValues(alpha: .7)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  if (overview != null)
                    Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: .7),
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

  Widget _still() {
    final part = resumedPart;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: watched ? .4 : 1,
          child: Artwork(
            episode.thumbnail,
            placeholder: Center(
              child: Text(
                epNumber(episode.number),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant.withValues(alpha: .5),
                ),
              ),
            ),
          ),
        ),
        if (upNext)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(isTv ? 12 : 8),
            ),
          ),
        // Pops in when an episode is marked watched.
        Positioned(
          top: 8,
          right: 8,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutBack,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: !watched
                ? const SizedBox.shrink()
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
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
              backgroundColor: Colors.black54,
            ),
          ),
      ],
    );
  }
}

/// TV: a page of episodes as a row of 16:9 stills, opening scrolled to [start] (the one up next).
class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.count,
    required this.start,
    required this.itemBuilder,
  });

  static const width = 240.0;

  final int count, start;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  late final controller = ScrollController(
    initialScrollOffset:
        widget.start.clamp(0, widget.count) * (_EpisodeRow.width + gutter),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TvRow(
    child: SizedBox(
      height: _EpisodeRow.width * 9 / 16 + 88,
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        // Clipped to the row, with room at the top for a focused still to grow.
        padding: const EdgeInsets.fromLTRB(tvMargin, 12, tvMargin, 0),
        itemCount: widget.count,
        separatorBuilder: (_, _) => SizedBox(width: gutter),
        itemBuilder: (context, i) => Align(
          alignment: Alignment.topLeft,
          child: widget.itemBuilder(context, i),
        ),
      ),
    ),
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
          icon: Icon(Icons.download_rounded, color: scheme.onSurfaceVariant),
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
          icon: Icon(Icons.schedule_rounded, color: scheme.onSurfaceVariant),
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
          icon: Icon(Icons.download_done_rounded, color: scheme.primary),
          onPressed: () => confirmDeleteDownload(context, d!),
        ),
        DownloadStatus.failed => IconButton(
          tooltip: d!.error ?? 'Download failed',
          icon: Icon(Icons.error_outline_rounded, color: scheme.error),
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
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        filled: false,
      ),
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
            style: TextStyle(color: scheme.onSurfaceVariant),
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

Future<void> confirmDeleteDownload(BuildContext context, Download d) async {
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
          autofocus: isTv,
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

/// Plays the finished downloads of [download]'s show and audio, from [download].
Future<void> playDownload(
  BuildContext context,
  Download download,
  List<Download> group,
) {
  final playable = [
    for (final d in group)
      if (d.status == DownloadStatus.done && d.dub == download.dub) d,
  ]..sort((a, b) => a.number.compareTo(b.number));
  return _openPlayer(
    context,
    media: download.media,
    source: null,
    sourceName: download.source,
    episodes: [for (final d in playable) d.episode],
    index: playable.indexOf(download),
    dub: download.dub,
  );
}
