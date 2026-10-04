import 'package:flutter/material.dart';

import '../anilist.dart';
import '../details.dart';
import '../home_feed.dart';
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';
import 'widgets.dart';

/// Desktop Schedule: the week as a board, a column a day with each episode at its time, so the whole week is
/// in view at once. Today's column is lit and its next episode marked.
class DeskSchedule extends StatefulWidget {
  const DeskSchedule(
    this.feed, {
    super.key,
    required this.onRefresh,
    required this.onReload,
  });

  final HomeFeed feed;
  final Future<void> Function() onRefresh;
  final void Function({bool force}) onReload;

  @override
  State<DeskSchedule> createState() => _DeskScheduleState();
}

class _DeskScheduleState extends State<DeskSchedule> {
  bool allShows = false;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeskHeader(
          'This week',
          note: Tracker.signedIn && !allShows
              ? 'Episodes of the shows on your list and the ones you watched recently'
              : 'Episodes of popular shows airing now',
          actions: [
            if (Tracker.signedIn)
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('My shows')),
                  ButtonSegment(value: true, label: Text('All shows')),
                ],
                selected: {allShows},
                onSelectionChanged: (v) => setState(() => allShows = v.first),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: FutureBuilder(
            future: allShows && Tracker.signedIn
                ? widget.feed.allSchedule
                : widget.feed.schedule,
            builder: (context, snap) {
              if (snap.hasError) {
                return ErrorState(snap.error!, onRetry: widget.onRefresh);
              }
              if (!snap.hasData) return const _Loading();
              final slots = snap.data!;
              if (slots.isEmpty) {
                return const EmptyState(
                  icon: Icons.event_available_outlined,
                  title: 'Nothing airs this week',
                  message: 'Episodes of the shows on your list and the ones you watch show up here.',
                );
              }
              return LayoutBuilder(
                builder: (context, box) {
                  const gap = 12.0;
                  final inner = box.maxWidth - deskMargin * 2;
                  final column = ((inner - gap * 6) / 7).clamp(168.0, 400.0);
                  final board = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 7; i++) ...[
                        if (i > 0) const SizedBox(width: gap),
                        SizedBox(
                          width: column,
                          child: Reveal(
                            index: i,
                            child: _Day(
                              i,
                              scheduleDay(slots, now, i),
                              onChanged: () => widget.onReload(force: true),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                  // A narrow window scrolls the board sideways; a wide one fits it.
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: deskMargin),
                    child: SizedBox(
                      width: column * 7 + gap * 6,
                      height: box.maxHeight,
                      child: board,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: deskMargin),
    child: Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 12),
              child: const Skeleton(radius: 14),
            ),
          ),
      ],
    ),
  );
}

class _Day extends StatelessWidget {
  const _Day(this.day, this.slots, {required this.onChanged});

  final int day;
  final ({List<Map> shown, Map? next, List<Map> rest}) slots;
  final VoidCallback onChanged;

  static const _names = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final date = scheduleDate(DateTime.now(), day);
    final today = day == 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: today
            ? scheme.primary.withValues(alpha: .08)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: today
            ? Border.all(color: scheme.primary.withValues(alpha: .5))
            : null,
        boxShadow: today ? null : ringShadow(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  today ? 'TODAY' : _names[date.weekday - 1],
                  style: text.labelSmall?.copyWith(
                    color: today ? scheme.primary : scheme.onSurfaceVariant,
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(width: 8),
                Text('${date.day}', style: text.titleLarge),
                const Spacer(),
                Text(
                  '${slots.shown.length}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: hairline),
          Expanded(
            child: slots.shown.isEmpty
                ? Center(
                    child: Text(
                      'Nothing airs',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: slots.shown.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _Slot(
                      slots.shown[i],
                      next: identical(slots.shown[i], slots.next),
                      onChanged: onChanged,
                    ),
                  ),
          ),
        ],
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

class _Slot extends StatelessWidget {
  const _Slot(this.slot, {required this.next, required this.onChanged});

  final Map slot;
  final bool next;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = slot['media'] as Map;
    final show = Show(media);
    final at = airsAt(slot);
    final aired = at.isBefore(DateTime.now());
    return Hover(
      pressScale: .98,
      onTap: () => openDetails(context, media, onBack: onChanged),
      builder: (context, hovered) => AnimatedContainer(
        duration: motionMs(context, 120),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: hovered
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: next ? scheme.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 64,
                child: Artwork(show.cover, color: show.color),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _time(context, at),
                    style: text.labelMedium?.copyWith(
                      color: aired ? scheme.onSurfaceVariant : scheme.primary,
                      // Times line up down the column, whatever the digits.
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    show.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'EP ${slot['episode']}${aired
                        ? ' · aired'
                        : next
                        ? ' · next'
                        : ''}',
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
    );
  }
}
