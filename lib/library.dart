import 'dart:math';

import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'details.dart';
import 'history.dart';
import 'home_feed.dart';
import 'player.dart';
import 'selection.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';

/// A tab's large headline and a note beside or under it.
class _Headline extends StatelessWidget {
  const _Headline(this.title, {this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, isTv ? 24 : 12, side, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.headlineMedium),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note!,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────────── My list ─────────────────────────────

final _statuses = ListStatus.movable;

/// Moves [media] to list [status] on AniList; completed counts every episode watched.
Future<bool> _moveTo(Map media, String status) =>
    Tracker.save(media, Show(media).progress, status: status);

/// Tells how a bulk change went: [done] when every one saved, else how many didn't.
void _report(BuildContext context, BulkResult result, String done) => result.ok
    ? showSuccess(context, bulkMessage(result, done))
    : showError(context, bulkMessage(result, done));

/// A page of posters where holding shows picks them to add to your list together (Home, Search): the posters
/// under it join in, and while picking, the selection bar covers the top of the page. Just [child] when signed out.
class PickingScope extends StatefulWidget {
  const PickingScope({super.key, required this.child, this.onChanged});

  final Widget child;

  /// Shows were added or moved.
  final VoidCallback? onChanged;

  @override
  State<PickingScope> createState() => _PickingScopeState();
}

class _PickingScopeState extends State<PickingScope> {
  final picking = Picking();

  @override
  void dispose() {
    picking.dispose();
    super.dispose();
  }

  Future<void> _addTo() async {
    final to = await pickOne(context, 'Add to', _statuses, 'PLANNING');
    if (to == null || !mounted) return;
    final result = await picking.runBulk((media) => _moveTo(media, to));
    if (!mounted) return;
    _report(context, result, 'Added ${result.total} to ${_statuses[to]}');
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!Tracker.signedIn) return widget.child;
    return ListenableBuilder(
      listenable: picking,
      builder: (context, child) => PopScope(
        canPop: !picking.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !picking.busy) picking.clear();
        },
        child: Stack(
          children: [
            child!,
            if (picking.active)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: scheme.surface,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        side - 8,
                        isTv ? 16 : 4,
                        side - 8,
                        0,
                      ),
                      child: SelectionBar(
                        count: picking.count,
                        busy: picking.busy,
                        onDone: picking.clear,
                        actions: [
                          IconButton(
                            tooltip: 'Add to list',
                            onPressed: picking.busy ? null : _addTo,
                            icon: const Icon(Icons.playlist_add_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      child: PickingProvider(notifier: picking, child: widget.child),
    );
  }
}

/// Your AniList list, one status at a time, as a grid of posters.
class MyListScreen extends StatefulWidget {
  const MyListScreen({
    super.key,
    required this.lists,
    required this.onRefresh,
    required this.onChanged,
    required this.onSignIn,
  });

  /// Every list, keyed by status (see [Tracker.lists] with `all`).
  final Future<Map<String, List>> lists;
  final Future<void> Function() onRefresh;

  /// A show was opened and may have changed.
  final VoidCallback onChanged;
  final VoidCallback onSignIn;

  @override
  State<MyListScreen> createState() => _MyListScreenState();
}

class _MyListScreenState extends State<MyListScreen> {
  String status = 'CURRENT';

  /// Shows picked for a bulk edit.
  final picking = Picking();

  void _toggle(Map media) {
    if (picking.toggle(media)) selectionTick();
  }

  /// Runs [change] on each picked show, then reloads.
  Future<void> _bulk(
    Future<bool> Function(Map media) change,
    String done,
  ) async {
    final result = await picking.runBulk(change);
    if (!mounted) return;
    _report(context, result, done);
    await widget.onRefresh();
  }

  Future<void> _changeStatus() async {
    final to = await pickOne(context, 'Move to', _statuses, status);
    if (to == null || !mounted) return;
    await _bulk(
      (media) => _moveTo(media, to),
      'Moved ${picking.count} to ${_statuses[to]}',
    );
  }

  Future<void> _remove() async {
    final count = picking.count;
    final ok = await confirmDestructive(
      context,
      title: 'Remove $count from your list?',
      message: 'Their progress and status on AniList are deleted too.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    await _bulk((media) async {
      await Tracker.removeFromList(media);
      return true;
    }, 'Removed $count from your list');
  }

  /// Replaces the headline while picking: how many, and what to do with them.
  Widget _selectionBar(List shown) => Padding(
    padding: EdgeInsets.fromLTRB(side - 8, isTv ? 16 : 4, side - 8, 0),
    child: SelectionBar(
      count: picking.count,
      busy: picking.busy,
      onDone: picking.clear,
      onAll: () => picking.selectAll(shown.cast<Map>()),
      actions: [
        IconButton(
          tooltip: 'Change status',
          onPressed: picking.busy ? null : _changeStatus,
          icon: const Icon(Icons.drive_file_move_outline),
        ),
        IconButton(
          tooltip: 'Remove from list',
          color: scheme.error,
          onPressed: picking.busy ? null : _remove,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ),
  );

  @override
  void initState() {
    super.initState();
    picking.addListener(() => setState(() {}));
    Analytics.screen('/list', title: 'My list');
  }

  @override
  void dispose() {
    picking.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: !Tracker.signedIn
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Headline('My list'),
                Expanded(
                  child: EmptyState(
                    icon: Icons.bookmarks_outlined,
                    title: 'Sign in with AniList',
                    message: 'Your watching, planning and completed shows show up here.',
                    action: FilledButton(
                      autofocus: isTv,
                      onPressed: widget.onSignIn,
                      child: const Text('Sign in'),
                    ),
                  ),
                ),
              ],
            )
          : FutureBuilder(
              future: widget.lists,
              builder: (context, snap) {
                final lists = snap.data ?? const {};
                final total = lists.values.fold(0, (n, l) => n + l.length);
                final shown = lists[status] ?? const [];
                return Column(
                  children: [
                    if (picking.active)
                      Material(
                        color: scheme.surface,
                        child: _selectionBar(shown),
                      ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: widget.onRefresh,
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            if (!picking.active)
                              SliverToBoxAdapter(
                                child: _Headline(
                                  'My list',
                                  note: snap.hasData
                                      ? '$total titles · ${isTv ? 'hold OK on' : 'hold'} one to edit several'
                                      : null,
                                ),
                              ),
                            SliverToBoxAdapter(child: _chips(lists)),
                            if (snap.hasError)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: ErrorState(
                                  snap.error!,
                                  onRetry: widget.onRefresh,
                                ),
                              )
                            else if (!snap.hasData)
                              _grid(12, (_, _) => const _PosterSkeleton())
                            else if (shown.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: EmptyState(
                                  icon: Icons.video_library_outlined,
                                  title:
                                      'Nothing ${_statuses[status]!.toLowerCase()}',
                                ),
                              )
                            else
                              _grid(
                                shown.length,
                                (context, i) => FadeIn(
                                  key: ValueKey((status, i)),
                                  index: i,
                                  child: PosterCard(
                                    shown[i],
                                    autofocus: isTv && i == 0,
                                    onBack: widget.onChanged,
                                    selected: picking.active
                                        ? picking.has(shown[i])
                                        : null,
                                    onTap: picking.active
                                        ? () => _toggle(shown[i])
                                        : null,
                                    onLongPress: () => _toggle(shown[i]),
                                  ),
                                ),
                              ),
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height:
                                    24 + MediaQuery.paddingOf(context).bottom,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    ),
  );

  Widget _chips(Map<String, List> lists) => SizedBox(
    height: 56,
    child: TvRow(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(side, 12, side, 4),
        itemCount: _statuses.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final MapEntry(:key, :value) = _statuses.entries.elementAt(i);
          final count = lists[key]?.length;
          return ChoiceChip(
            showCheckmark: false,
            label: Text(count == null ? value : '$value · $count'),
            selected: key == status,
            onSelected: (_) {
              if (key == status || picking.busy) return;
              selectionTick();
              picking.clear(); // picks are made within one list
              setState(() => status = key);
            },
          );
        },
      ),
    ),
  );

  /// Two big posters across a phone (Marquee), the usual grid on TV.
  Widget _grid(int count, NullableIndexedWidgetBuilder builder) =>
      SliverPadding(
        padding: EdgeInsets.fromLTRB(side, 12, side, 0),
        sliver: SliverGrid.builder(
          gridDelegate: posterGrid,
          itemCount: count,
          itemBuilder: builder,
        ),
      );
}

/// Every show in Recently watched, newest first. Hold shows to change their AniList status or take them off the row.
class RecentlyWatchedScreen extends StatefulWidget {
  const RecentlyWatchedScreen({super.key});

  @override
  State<RecentlyWatchedScreen> createState() => _RecentlyWatchedScreenState();
}

class _RecentlyWatchedScreenState extends State<RecentlyWatchedScreen> {
  late Future<List<WatchRecord>> records = WatchHistory.all();

  /// Shows picked.
  final picking = Picking();

  @override
  void initState() {
    super.initState();
    picking.addListener(() => setState(() {}));
    Analytics.screen('/recent', title: 'Recently watched');
  }

  @override
  void dispose() {
    picking.dispose();
    super.dispose();
  }

  void _toggle(Map media) {
    if (picking.toggle(media)) selectionTick();
  }

  Future<void> _changeStatus() async {
    final to = await pickOne(context, 'Move to', _statuses, 'CURRENT');
    if (to == null || !mounted) return;
    final done = 'Moved ${picking.count} to ${_statuses[to]}';
    final result = await picking.runBulk((media) async {
      final saved = await _moveTo(media, to);
      // Finished or given up on: nothing left to continue.
      if (to == 'COMPLETED' || to == 'DROPPED') {
        await WatchHistory.remove(media);
      }
      return saved;
    });
    _done(result, done);
  }

  Future<void> _remove() async {
    final done = 'Removed ${picking.count} from recently watched';
    _done(
      await picking.runBulk((media) async {
        await WatchHistory.remove(media);
        return true;
      }),
      done,
    );
  }

  void _done(BulkResult result, String message) {
    if (!mounted) return;
    setState(() => records = WatchHistory.all());
    _report(context, result, message);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !picking.active,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !picking.busy) picking.clear();
    },
    child: Scaffold(
      appBar: picking.active
          ? null
          : AppBar(
              title: const Text('Recently watched'),
              toolbarHeight: isTv ? 72 : 64,
              titleSpacing: side,
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
      body: SafeArea(
        top: picking.active,
        bottom: false,
        child: FutureBuilder(
          future: records,
          builder: (context, snap) {
            final list = snap.data ?? const <WatchRecord>[];
            return Column(
              children: [
                if (picking.active)
                  Material(
                    color: scheme.surface,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(side - 8, 4, side - 8, 0),
                      child: SelectionBar(
                        count: picking.count,
                        busy: picking.busy,
                        onDone: picking.clear,
                        onAll: () =>
                            picking.selectAll([for (final r in list) r.media]),
                        actions: [
                          if (Tracker.signedIn)
                            IconButton(
                              tooltip: 'Change status',
                              onPressed: picking.busy ? null : _changeStatus,
                              icon: const Icon(Icons.drive_file_move_outline),
                            ),
                          IconButton(
                            tooltip: 'Remove from recently watched',
                            color: scheme.error,
                            onPressed: picking.busy ? null : _remove,
                            icon: const Icon(Icons.history_toggle_off_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: _grid(snap, list)),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _grid(AsyncSnapshot<List<WatchRecord>> snap, List<WatchRecord> list) {
    if (snap.hasError) {
      return ErrorState(
        snap.error!,
        onRetry: () => setState(() => records = WatchHistory.all()),
      );
    }
    if (snap.hasData && list.isEmpty) {
      return const EmptyState(
        icon: Icons.history_rounded,
        title: 'Nothing watched yet',
        message: 'Shows you start watching show up here.',
      );
    }
    final text = Theme.of(context).textTheme;
    return CustomScrollView(
      slivers: [
        if (!picking.active)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: Text(
                '${isTv ? 'Hold OK on' : 'Hold'} a show to change its status or remove it',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            side,
            12,
            side,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          sliver: !snap.hasData
              ? SliverGrid.builder(
                  gridDelegate: posterGrid,
                  itemCount: 6,
                  itemBuilder: (_, _) => const _PosterSkeleton(),
                )
              : SliverGrid.builder(
                  gridDelegate: posterGrid,
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final r = list[i];
                    return FadeIn(
                      index: i,
                      child: PosterCard(
                        r.media,
                        subtitle:
                            'EP ${epNumber(r.episode)}'
                            '${r.position > Duration.zero ? ' · ${formatDuration(r.position)}' : ''}',
                        autofocus: isTv && i == 0,
                        onBack: () =>
                            setState(() => records = WatchHistory.all()),
                        selected: picking.active ? picking.has(r.media) : null,
                        onTap: picking.active ? () => _toggle(r.media) : null,
                        onLongPress: () => _toggle(r.media),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _PosterSkeleton extends StatelessWidget {
  const _PosterSkeleton();

  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.topCenter,
    child: AspectRatio(aspectRatio: 2 / 3, child: Skeleton()),
  );
}

// ───────────────────────────── Schedule ─────────────────────────────

/// This week's episodes of the shows on your list and the ones you watched recently, a day at a time.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    required this.schedule,
    required this.allSchedule,
    required this.onRefresh,
    required this.onChanged,
  });

  /// From [AniList.airingAround], from the start of today.
  final Future<List<Map>> schedule;
  final Future<List<Map>> allSchedule;
  final Future<void> Function() onRefresh;
  final VoidCallback onChanged;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  /// Days from today.
  int day = 0;
  bool allShows = false;

  @override
  void initState() {
    super.initState();
    Analytics.screen('/schedule', title: 'Schedule');
  }

  @override
  Widget build(BuildContext context) =>
      PickingScope(onChanged: widget.onChanged, child: _page(context));

  Widget _page(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: FutureBuilder(
        future: allShows && Tracker.signedIn
            ? widget.allSchedule
            : widget.schedule,
        builder: (context, snap) {
          final all = snap.data ?? const <Map>[];
          final (:shown, :next, :rest) = scheduleDay(all, DateTime.now(), day);
          return RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _Headline(
                    'This week',
                    note: snap.hasData
                        ? '${all.length} ${all.length == 1 ? 'episode' : 'episodes'} '
                              '${Tracker.signedIn && !allShows ? 'from your list and recent shows' : 'of popular shows airing now'}'
                        : null,
                  ),
                ),
                if (Tracker.signedIn)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(side, 12, side, 0),
                      child: SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, label: Text('My shows')),
                          ButtonSegment(value: true, label: Text('All shows')),
                        ],
                        selected: {allShows},
                        onSelectionChanged: (value) => setState(() {
                          allShows = value.first;
                        }),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: _days()),
                if (snap.hasError)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: ErrorState(snap.error!, onRetry: widget.onRefresh),
                  )
                else if (!snap.hasData)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(side, 16, side, 0),
                    sliver: SliverList.separated(
                      itemCount: 4,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, _) => const Skeleton(height: 70),
                    ),
                  )
                else if (shown.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.event_available_outlined,
                      title: 'Nothing airs this day',
                      message: 'Episodes of the shows on your list and the ones you watch show up here.',
                    ),
                  )
                else
                  _episodesOf(rest, next),
              ],
            ),
          );
        },
      ),
    ),
  );

  /// The day's episodes: the next one up as a wide card, the rest as rows; two columns of them on TV, where one
  /// would stretch a still and a time across the whole screen.
  Widget _episodesOf(List<Map> rest, Map? next) {
    Widget slot(BuildContext context, int i) => FadeIn(
      key: ValueKey((day, i)),
      index: i + (next == null ? 0 : 1),
      child: _Slot(
        rest[i],
        autofocus: isTv && next == null && i == 0,
        onChanged: widget.onChanged,
      ),
    );
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        side,
        16,
        side,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      sliver: SliverMainAxisGroup(
        slivers: [
          if (next != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FadeIn(
                  key: ValueKey((day, 'next')),
                  child: _NextUp(
                    next,
                    autofocus: isTv,
                    onChanged: widget.onChanged,
                  ),
                ),
              ),
            ),
          if (isTv)
            SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 820,
                mainAxisExtent: 70,
                crossAxisSpacing: gutter,
                mainAxisSpacing: 12,
              ),
              itemCount: rest.length,
              itemBuilder: slot,
            )
          else
            SliverList.separated(
              itemCount: rest.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: slot,
            ),
        ],
      ),
    );
  }

  /// Today and the six days after it as date pills, with one accent pill that slides to the day picked.
  Widget _days() {
    const width = 56.0, gap = 8.0;
    final text = Theme.of(context).textTheme;
    final still = MediaQuery.disableAnimationsOf(context);
    final motion = still ? Duration.zero : const Duration(milliseconds: 320);
    return TvRow(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(side, 16, side, 0),
        child: SizedBox(
          width: 7 * width + 6 * gap,
          height: 68,
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: motion,
                curve: Curves.easeOutCubic,
                left: day * (width + gap),
                top: 0,
                bottom: 0,
                width: width,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(buttonRadius),
                  ),
                ),
              ),
              for (var i = 0; i < 7; i++)
                Positioned(
                  left: i * (width + gap),
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: _day(i, text, motion),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _day(int i, TextTheme text, Duration motion) {
    final date = scheduleDate(DateTime.now(), i);
    final on = i == day;
    final color = on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Semantics(
      selected: on,
      child: InkWell(
        borderRadius: BorderRadius.circular(buttonRadius),
        onTap: () {
          if (on) return;
          selectionTick();
          setState(() => day = i);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedDefaultTextStyle(
              duration: motion,
              style: text.labelSmall!.copyWith(color: color, letterSpacing: .8),
              child: Text(
                i == 0
                    ? 'TODAY'
                    : const [
                        'MON',
                        'TUE',
                        'WED',
                        'THU',
                        'FRI',
                        'SAT',
                        'SUN',
                      ][date.weekday - 1],
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: motion,
              style: text.titleLarge!.copyWith(
                color: on ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
              child: Text('${date.day}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "21:00" (or "9:00 PM"), as the device formats times.
String _time(BuildContext context, DateTime at) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(at),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// "in 2h 14m", "in 40m", or "aired".
String _until(DateTime at) {
  final left = at.difference(DateTime.now());
  if (left.isNegative) return 'aired';
  return left.inHours > 0
      ? 'in ${left.inHours}h ${left.inMinutes % 60}m'
      : 'in ${left.inMinutes}m';
}

/// The next episode today, over its show's art.
class _NextUp extends StatelessWidget {
  const _NextUp(this.slot, {required this.onChanged, this.autofocus = false});

  final Map slot;
  final VoidCallback onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = slot['media'] as Map;
    final show = Show(media);
    final at = airsAt(slot);
    final join = Picking.join(
      context,
      media,
      open: () => openDetails(context, media, onBack: onChanged),
    );
    final picked = join.selected;
    return FocusCard(
      radius: radiusLarge,
      autofocus: autofocus,
      glow: hexColor(show.color),
      semanticLabel: '${show.title}, episode ${slot['episode']}, ${_until(at)}',
      onTap: join.onTap,
      onLongPress: join.onLongPress,
      child: SizedBox(
        height: isTv ? 220 : 170,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(
              show.backdrop,
              color: show.color,
              alignment: Alignment.topCenter,
              full: show.hasBanner,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [scheme.surface.withValues(alpha: 0), scheme.surface],
                  stops: const [.2, 1],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow('Next up · ${_until(at)}'),
                  const SizedBox(height: 4),
                  Text(
                    show.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleLarge,
                  ),
                  Text(
                    'EP ${slot['episode']} · ${_time(context, at)}',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (picked != null) ...pickOverlay(picked),
          ],
        ),
      ),
    );
  }
}

/// One episode in the day: a still, the show and episode, and when it airs.
class _Slot extends StatelessWidget {
  const _Slot(this.slot, {required this.onChanged, this.autofocus = false});

  final Map slot;
  final VoidCallback onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = slot['media'] as Map;
    final show = Show(media);
    final at = airsAt(slot);
    final aired = at.isBefore(DateTime.now());
    final join = Picking.join(
      context,
      media,
      open: () => openDetails(context, media, onBack: onChanged),
    );
    final picked = join.selected;
    return FocusCard(
      radius: nested(8, radiusSmall), // the small still, 8dp in: large
      autofocus: autofocus,
      glow: hexColor(show.color),
      semanticLabel:
          '${show.title}, episode ${slot['episode']}, ${_time(context, at)}',
      onTap: join.onTap,
      onLongPress: join.onLongPress,
      child: Stack(
        children: [
          ColoredBox(
            color: scheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radiusSmall),
                    child: SizedBox(
                      width: 96,
                      height: 54,
                      child: Artwork(
                        show.cover,
                        color: show.color,
                        alignment: const Alignment(0, -.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          show.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium,
                        ),
                        Text(
                          'EP ${slot['episode']}${aired ? ' · aired' : ''}',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      _time(context, at),
                      style: text.labelLarge?.copyWith(
                        color: aired ? scheme.onSurfaceVariant : scheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Over the leading still, clear of the air time.
          if (picked != null)
            Positioned.fill(
              child: Stack(
                fit: StackFit.expand,
                children: pickOverlay(
                  picked,
                  radius: nested(8, radiusSmall),
                  leading: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Stats ─────────────────────────────

/// Days in a row, ending today (or yesterday, before today's first update), with list activity. [active] holds
/// local dates at midnight.
int activityStreak(Set<DateTime> active, DateTime today) {
  var day = DateTime(today.year, today.month, today.day);
  if (!active.contains(day)) day = DateTime(day.year, day.month, day.day - 1);
  var streak = 0;
  while (active.contains(day)) {
    streak++;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return streak;
}

/// The statuses in the stats ring, clockwise from the top.
const _statusOrder = [
  ListStatus.completed,
  ListStatus.current,
  ListStatus.planning,
  ListStatus.paused,
  ListStatus.dropped,
];

/// Your AniList totals: time spent watching, your list by status as a ring, and the last 20 weeks of activity.
class StatsView extends StatelessWidget {
  const StatsView(this.stats, {super.key, required this.onRetry});

  /// From [AniList.stats].
  final Future<Map<String, dynamic>?> stats;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: stats,
    builder: (context, snap) {
      if (snap.hasError) {
        return ErrorState(snap.error!, compact: true, onRetry: onRetry);
      }
      final data = snap.data;
      if (data == null) {
        return snap.connectionState == ConnectionState.done
            ? const SizedBox.shrink() // signed out
            : Padding(
                padding: EdgeInsets.all(side),
                child: const Skeleton(height: 320),
              );
      }
      final anime = data['statistics']['anime'] as Map;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: side),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FadeIn(child: _spent(context, anime)),
            const SizedBox(height: 24),
            FadeIn(index: 2, child: _statuses(context, anime)),
            const SizedBox(height: 24),
            FadeIn(
              index: 4,
              child: _activity(
                context,
                data['stats']?['activityHistory'] as List?,
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _spent(BuildContext context, Map anime) {
    final text = Theme.of(context).textTheme;
    final days = (anime['minutesWatched'] as int? ?? 0) / 1440;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "You've spent",
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        // Counts up to the total.
        _CountUp(
          days,
          builder: (context, value) => Text.rich(
            TextSpan(
              text: value.toStringAsFixed(1),
              children: [
                TextSpan(
                  text: ' days',
                  style: text.headlineSmall?.copyWith(
                    fontSize: 22,
                    letterSpacing: 0,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            style: text.displayLarge?.copyWith(
              fontSize: 64,
              height: 1,
              letterSpacing: -2.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'watching anime. ${anime['episodesWatched'] ?? 0} episodes across ${anime['count'] ?? 0} titles.',
          style: text.bodySmall?.copyWith(color: scheme.primary),
        ),
      ],
    );
  }

  Widget _statuses(BuildContext context, Map anime) {
    final text = Theme.of(context).textTheme;
    final counts = {
      for (final s in anime['statuses'] as List? ?? const [])
        s['status'] as String: s['count'] as int,
    };
    // REPEATING counts as watching.
    counts['CURRENT'] = (counts['CURRENT'] ?? 0) + (counts['REPEATING'] ?? 0);
    final colors = [
      scheme.primary,
      scheme.primary.withValues(alpha: .6),
      scheme.primaryContainer,
      scheme.outline,
      scheme.surfaceContainerHighest,
    ];
    final slices = [
      for (final (i, status) in _statusOrder.indexed)
        (status.label, counts[status.value] ?? 0, colors[i]),
    ];
    final total = slices.fold(0, (n, s) => n + s.$2);
    return Row(
      children: [
        SizedBox.square(
          dimension: 120,
          // The ring draws itself round as the total counts up.
          child: _CountUp(
            1,
            builder: (context, t) => CustomPaint(
              painter: _Ring([for (final s in slices) (s.$2, s.$3)], t),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${(total * t).round()}', style: text.titleLarge),
                    Text(
                      'titles',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            children: [
              for (final (label, count, color) in slices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(label, style: text.bodySmall)),
                      Text(
                        '$count',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 20 weeks as columns of days, oldest first, shaded by how much you updated your list.
  Widget _activity(BuildContext context, List? history) {
    final text = Theme.of(context).textTheme;
    final amounts = <DateTime, int>{};
    for (final h in history ?? const []) {
      final at = DateTime.fromMillisecondsSinceEpoch((h['date'] as int) * 1000);
      final day = DateTime(at.year, at.month, at.day);
      amounts[day] = (amounts[day] ?? 0) + (h['amount'] as int? ?? 0);
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // The grid ends with this week's column; its days after today stay empty.
    final start = DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - 1) - 19 * 7,
    );
    final streak = activityStreak(amounts.keys.toSet(), today);
    Color shade(int amount) => switch (amount) {
      0 => scheme.surfaceContainerHigh,
      <= 2 => scheme.primaryContainer,
      <= 5 => scheme.primary.withValues(alpha: .6),
      _ => scheme.primary,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text('Last 20 weeks', style: text.titleSmall)),
            Text(
              '$streak-day streak',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var week = 0; week < 20; week++) ...[
              if (week > 0) const SizedBox(width: 3),
              Expanded(
                child: Column(
                  children: [
                    for (var d = 0; d < 7; d++) ...[
                      if (d > 0) const SizedBox(height: 3),
                      () {
                        final day = DateTime(
                          start.year,
                          start.month,
                          start.day + week * 7 + d,
                        );
                        return Container(
                          height: 11,
                          decoration: BoxDecoration(
                            color: day.isAfter(today)
                                ? Colors.transparent
                                : shade(amounts[day] ?? 0),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }(),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// A ring of slices, (count, colour) each, starting at the top.
class _Ring extends CustomPainter {
  _Ring(this.slices, this.drawn);

  final List<(int, Color)> slices;

  /// How much of the ring is drawn, 0–1.
  final double drawn;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0, gap = .04;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final total = slices.fold(0, (n, s) => n + s.$1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    if (total == 0) {
      canvas.drawArc(
        rect,
        0,
        6.2832,
        false,
        paint..color = scheme.surfaceContainerHigh,
      );
      return;
    }
    var angle = -1.5708;
    final end = angle + drawn * 6.2832;
    for (final (count, color) in slices) {
      if (count == 0 || angle >= end) continue;
      final sweep = min(count / total * 6.2832, end - angle);
      canvas.drawArc(
        rect,
        angle,
        (sweep - gap).clamp(.01, 6.2832),
        false,
        paint..color = color,
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(_Ring old) => old.slices != slices || old.drawn != drawn;
}

/// Animates from 0 to [value] once, over most of a second; straight to it when animations are off.
class _CountUp extends StatelessWidget {
  const _CountUp(this.value, {required this.builder});

  final double value;
  final Widget Function(BuildContext context, double value) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: value),
    duration: motionMs(context, 600),
    curve: Curves.easeOutCubic,
    builder: (context, v, _) => builder(context, v),
  );
}
