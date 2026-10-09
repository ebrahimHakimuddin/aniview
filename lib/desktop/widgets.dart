import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show SliverConstraints, SliverGridLayout, SliverGridRegularTileLayout;

import '../anilist.dart';
import '../details.dart';
import '../history.dart';
import '../player.dart' show formatDuration;
import '../sources.dart' show epNumber;
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';
import 'picks.dart';

/// The desktop UI's own pieces: pointer-first (hover reveals what a phone shows all the time, a right click opens a
/// menu), dense, and laid out for a window rather than a screen held in the hand.

const deskMargin = 32.0;
const deskPosterWidth = 172.0;
const deskCorner = radiusLarge;

/// A hairline edge and a soft lift, as two translucent shadows: unlike a solid border, they take the colour of
/// whatever is behind, so a card sits on the page instead of being drawn onto it.
List<BoxShadow> ringShadow() => [
  BoxShadow(
    color: scheme.onSurface.withValues(alpha: .09),
    spreadRadius: 1,
    blurRadius: 0,
  ),
  BoxShadow(
    color: Colors.black.withValues(alpha: .2),
    blurRadius: 16,
    offset: const Offset(0, 6),
  ),
];

/// Rebuilds with whether the pointer is over it, or the keyboard is on it (Tab, then Enter or Space); a click, and a
/// right click at the pointer's place. While pressed it dips by [pressScale], so a click is felt before it lands: a
/// hint on something small, barely there on something wide.
class Hover extends StatefulWidget {
  const Hover({
    super.key,
    required this.builder,
    this.onTap,
    this.onSecondary,
    this.cursor,
    this.pressScale = .97,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onSecondary;
  final MouseCursor? cursor;
  final double pressScale;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool hovered = false, focused = false, pressed = false;

  void _press(bool down) {
    if (widget.onTap != null && pressed != down) {
      setState(() => pressed = down);
    }
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    enabled: widget.onTap != null,
    mouseCursor:
        widget.cursor ??
        (widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click),
    onShowHoverHighlight: (v) => setState(() => hovered = v),
    onShowFocusHighlight: (v) => setState(() => focused = v),
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onTap?.call();
          return null;
        },
      ),
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      onSecondaryTapUp: widget.onSecondary == null
          ? null
          : (d) => widget.onSecondary!(d.globalPosition),
      child: AnimatedScale(
        scale: pressed && !MediaQuery.disableAnimationsOf(context)
            ? widget.pressScale
            : 1,
        // In fast, out a touch slower: the press is the system answering, the release settles.
        duration: Duration(milliseconds: pressed ? 90 : 160),
        curve: deskEaseOut,
        child: widget.builder(context, hovered || focused),
      ),
    ),
  );
}

/// Moves [media] to list [status], saying how it went; [onChanged] after.
Future<void> setListStatus(
  BuildContext context,
  Map media,
  String status, {
  VoidCallback? onChanged,
}) async {
  try {
    final saved = await Tracker.save(
      media,
      Show(media).progress,
      status: status,
    );
    if (!context.mounted) return;
    showSuccess(
      context,
      saved
          ? '${titleOf(media)} · ${ListStatus.labels[status]}'
          : 'Saved on this device · syncs when ${Tracker.account?.name ?? 'AniList'} is back',
    );
    onChanged?.call();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// A menu at [at]: the list statuses, as a context menu or the ＋ button gives them.
List<PopupMenuEntry<String>> statusItems(Map media) => [
  for (final MapEntry(:key, :value) in ListStatus.movable.entries)
    CheckedPopupMenuItem(
      value: key,
      checked: Show(media).listStatus == key,
      child: Text(value),
    ),
];

/// The round checkbox that picks an item among several: on hover, and for as long as picking goes on. A click on it
/// picks (or unpicks) without opening the item.
class PickBox extends StatelessWidget {
  const PickBox({
    super.key,
    required this.picked,
    required this.onTap,
    this.onDark = true,
  });

  final bool picked;
  final VoidCallback onTap;

  /// Over a picture (white when unchecked), or on the page itself.
  final bool onDark;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          picked
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: picked
              ? scheme.primary
              : onDark
              ? Colors.white
              : scheme.onSurfaceVariant,
          shadows: onDark ? const [Shadow(blurRadius: 6)] : null,
        ),
      ),
    ),
  );
}

/// Where a right click at [at] (window coordinates) puts a menu. A page in the shell sits in a Navigator that starts
/// below the top bar and beside the sidebar, and a menu's position is relative to that.
RelativeRect menuAt(BuildContext context, Offset at) {
  final box = Navigator.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(
    box.globalToLocal(at) & Size.zero,
    Offset.zero & box.size,
  );
}

/// A grid of [DeskPoster]s: as many columns as fit, each cell as tall as its poster (2:3, so it grows with the
/// column) plus the room for two lines of title and one of facts.
class DeskPosterGrid extends SliverGridDelegate {
  const DeskPosterGrid();

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    const spacing = 20.0, rowGap = 12.0, captions = 72.0;
    final count =
        (constraints.crossAxisExtent / (deskPosterWidth + 24 + spacing)).ceil();
    final width = (constraints.crossAxisExtent - spacing * (count - 1)) / count;
    final height = width * 1.5 + captions;
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: height + rowGap,
      crossAxisStride: width + spacing,
      childMainAxisExtent: height,
      childCrossAxisExtent: width,
      reverseCrossAxis: false,
    );
  }

  @override
  bool shouldRelayout(DeskPosterGrid oldDelegate) => false;
}

/// A poster for a grid or row: the title under it, and on hover the way in, a play button, the facts and a ＋ to
/// put it on a list. A right click opens the same as a menu. With [onToggle] it can be picked among several.
class DeskPoster extends StatelessWidget {
  const DeskPoster(
    this.media, {
    super.key,
    this.subtitle,
    this.onChanged,
    this.selected,
    this.onToggle,
  });

  final Map media;
  final String? subtitle;

  /// Back from the show, or its list status changed.
  final VoidCallback? onChanged;

  /// Picking several: whether this one is picked (null when not picking), and how to pick it.
  final bool? selected;
  final VoidCallback? onToggle;

  void _open(BuildContext context, {bool play = false}) =>
      openDetails(context, media, onBack: onChanged, autoplay: play);

  Future<void> _menu(
    BuildContext context,
    Offset at,
    bool? selected,
    VoidCallback? onToggle,
  ) async {
    final picked = await showMenu<String>(
      context: context,
      position: menuAt(context, at),
      items: [
        const PopupMenuItem(value: '_open', child: Text('Open')),
        const PopupMenuItem(value: '_play', child: Text('Watch next episode')),
        if (onToggle != null)
          PopupMenuItem(
            value: '_pick',
            child: Text(selected == true ? 'Unselect' : 'Select'),
          ),
        if (Tracker.signedIn) ...[
          const PopupMenuDivider(),
          ...statusItems(media),
        ],
      ],
    );
    if (picked == null || !context.mounted) return;
    switch (picked) {
      case '_open':
        _open(context);
      case '_play':
        _open(context, play: true);
      case '_pick':
        onToggle!();
      default:
        await setListStatus(context, media, picked, onChanged: onChanged);
    }
  }

  /// Where it isn't given its own way to pick (My list has one), a poster joins the desktop-wide picks, when there's a
  /// list to put them on.
  @override
  Widget build(BuildContext context) => onToggle != null || !Tracker.signedIn
      ? _build(context, selected, onToggle)
      : ListenableBuilder(
          listenable: deskPicks,
          builder: (context, _) => _build(
            context,
            deskPicks.active ? deskPicks.has(media) : null,
            () => deskPicks.toggle(media),
          ),
        );

  Widget _build(BuildContext context, bool? selected, VoidCallback? onToggle) {
    final text = Theme.of(context).textTheme;
    final show = Show(media);
    final picking = selected != null;
    final progress = show.inList ? show.progress : null;
    final total = show.aired;
    final line =
        subtitle ??
        airingLabel(media) ??
        (progress == null
            ? null
            : 'EP $progress${total == null ? '' : ' / $total'}');
    return Hover(
      onTap: picking ? onToggle : () => _open(context),
      onSecondary: (at) => _menu(context, at, selected, onToggle),
      builder: (context, hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            scale: hovered && !picking ? 1.02 : 1,
            duration: motionMs(context, 160),
            curve: deskEaseOut,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: AnimatedContainer(
                duration: motionMs(context, 140),
                curve: Curves.ease,
                // A hair of an edge at rest, so a dark poster still has an outline on a dark page.
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(deskCorner),
                  border: Border.all(
                    color: selected == true
                        ? scheme.primary
                        : hovered
                        ? scheme.onSurface.withValues(alpha: .6)
                        : scheme.onSurface.withValues(alpha: .09),
                    width: selected == true ? 3 : (hovered ? 2 : 1),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(deskCorner),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Artwork(show.cover, color: show.color),
                      if (show.score case final score? when !hovered)
                        Positioned(top: 8, right: 8, child: Pill.score(score)),
                      if (progress != null &&
                          (progress > 0 || (total ?? 0) > 0))
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _Progress(watchedShare(progress, total)),
                        ),
                      AnimatedOpacity(
                        opacity: hovered ? 1 : 0,
                        duration: motionMs(context, 140),
                        child: _HoverOverlay(
                          media: media,
                          onPlay: () => _open(context, play: true),
                          onChanged: onChanged,
                          showAdd: !picking,
                        ),
                      ),
                      if (picking || (hovered && onToggle != null))
                        Positioned(
                          top: 2,
                          left: 2,
                          child: PickBox(
                            picked: selected == true,
                            onTap: onToggle!,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            show.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (line != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.share);

  final double share;

  @override
  Widget build(BuildContext context) => Container(
    height: progressBarHeight,
    color: Colors.black54,
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: share,
      child: ColoredBox(
        color: scheme.primary,
        child: const SizedBox(height: progressBarHeight),
      ),
    ),
  );
}

class _HoverOverlay extends StatelessWidget {
  const _HoverOverlay({
    required this.media,
    required this.onPlay,
    required this.onChanged,
    required this.showAdd,
  });

  final Map media;
  final VoidCallback onPlay;
  final VoidCallback? onChanged;
  final bool showAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final show = Show(media);
    final facts = [
      if (show.score != null) '★ ${show.score}%',
      mediaMeta(media, genres: 2),
    ].where((s) => s.isNotEmpty).join(' · ');
    final synopsis = plainText(show.description);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66000000), Color(0x33000000), Color(0xE6000000)],
          stops: [0, .45, 1],
        ),
      ),
      child: Stack(
        children: [
          Center(
            // Above the button: below it, the tip lands on the facts at the foot of the poster.
            child: Tooltip(
              message: 'Watch next episode',
              preferBelow: false,
              child: IconButton.filled(
                iconSize: 32,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ),
          ),
          if (showAdd && Tracker.signedIn)
            Positioned(
              top: 4,
              right: 4,
              child: PopupMenuButton<String>(
                tooltip: show.inList ? 'On your list' : 'Add to list',
                onSelected: (status) =>
                    setListStatus(context, media, status, onChanged: onChanged),
                itemBuilder: (_) => statusItems(media),
                icon: Icon(
                  show.inList
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 6)],
                ),
              ),
            ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  facts,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(color: Colors.white),
                ),
                if (synopsis.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      synopsis,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: .85),
                        fontSize: 11.5,
                        height: 1.3,
                      ),
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

/// A titled, horizontally scrolling row of [DeskPoster]s, with arrows over its ends on hover.
class DeskRow extends StatelessWidget {
  const DeskRow(
    this.title,
    this.items, {
    super.key,
    this.subtitles,
    this.onSeeAll,
    this.onChanged,
    this.onHide,
  });

  final String title;
  final List items;
  final List<String>? subtitles;
  final VoidCallback? onSeeAll, onChanged;

  /// Takes the row off Home: shows ⋯ by its title.
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) => _RowFrame(
    title: title,
    onSeeAll: onSeeAll,
    onHide: onHide,
    height: deskPosterWidth * 1.5 + 72,
    arrowTop: deskPosterWidth * .75 - 20,
    count: items.length,
    itemWidth: deskPosterWidth,
    itemBuilder: (context, i) =>
        DeskPoster(items[i], subtitle: subtitles?[i], onChanged: onChanged),
  );
}

const _rowBleed = 6.0;

/// The header and arrowed list under a row's title; [itemBuilder] draws each of [count] items [itemWidth] wide.
class _RowFrame extends StatelessWidget {
  const _RowFrame({
    required this.title,
    required this.height,
    required this.arrowTop,
    required this.count,
    required this.itemWidth,
    required this.itemBuilder,
    this.onSeeAll,
    this.onHide,
  });

  final String title;
  final double height, arrowTop, itemWidth;
  final int count;
  final IndexedWidgetBuilder itemBuilder;
  final VoidCallback? onSeeAll, onHide;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(deskMargin, 0, deskMargin - 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (onSeeAll != null)
                TextButton(onPressed: onSeeAll, child: const Text('See all')),
              if (onHide != null)
                PopupMenuButton<String>(
                  tooltip: 'Row options',
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  onSelected: (_) => onHide!(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'hide',
                      child: Row(
                        children: [
                          Icon(Icons.visibility_off_outlined, size: 20),
                          SizedBox(width: 12),
                          Text('Hide this row'),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        // A few pixels above and below the cards, so a hovered one (it grows a little, with an outline) isn't cut off by
        // the list's edge.
        SizedBox(
          height: height + 2 * _rowBleed,
          child: ScrollArrows(
            arrowTop: arrowTop + _rowBleed,
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: deskMargin,
                vertical: _rowBleed,
              ),
              itemCount: count,
              separatorBuilder: (_, _) => const SizedBox(width: 20),
              itemBuilder: (context, i) => SizedBox(
                width: itemWidth,
                // The first screenful arrives one after another; the rest are simply there when scrolled to.
                child: i < 10
                    ? Reveal(index: i, child: itemBuilder(context, i))
                    : itemBuilder(context, i),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Where you stopped, as wide cards: the show's banner, the episode and time left, and a bar. A click picks up
/// where you left off; ✕ on hover takes it off the row.
class DeskResumeRow extends StatelessWidget {
  const DeskResumeRow(
    this.title,
    this.records, {
    super.key,
    this.onChanged,
    this.onSeeAll,
    this.onHide,
  });

  final String title;
  final List<WatchRecord> records;
  final VoidCallback? onChanged, onSeeAll, onHide;

  static const width = 300.0;

  @override
  Widget build(BuildContext context) => _RowFrame(
    title: title,
    onSeeAll: onSeeAll,
    onHide: onHide,
    height: width * 9 / 16 + 70,
    arrowTop: width * 9 / 32 - 20,
    count: records.length,
    itemWidth: width,
    itemBuilder: (context, i) => _ResumeCard(records[i], onChanged: onChanged),
  );
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard(this.record, {this.onChanged});

  final WatchRecord record;
  final VoidCallback? onChanged;

  Future<void> _resume(BuildContext context) async {
    try {
      await resumeWatching(context, record);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final show = record.show;
    final duration = record.duration;
    final share = duration == null || duration == Duration.zero
        ? 0.0
        : (record.position.inMilliseconds / duration.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    final left = duration == null ? null : duration - record.position;
    final line = [
      'EP ${epNumber(record.episode)}',
      if (left != null && record.position > Duration.zero)
        '${formatDuration(left)} left',
    ].join(' · ');
    return Hover(
      onTap: () => _resume(context),
      onSecondary: (at) async {
        final picked = await showMenu<String>(
          context: context,
          position: menuAt(context, at),
          items: const [
            PopupMenuItem(value: 'play', child: Text('Resume')),
            PopupMenuItem(value: 'open', child: Text('Open show')),
            PopupMenuItem(value: 'remove', child: Text('Remove from row')),
          ],
        );
        if (!context.mounted) return;
        switch (picked) {
          case 'play':
            _resume(context);
          case 'open':
            openDetails(context, record.media, onBack: onChanged);
          case 'remove':
            await WatchHistory.remove(record.media);
            onChanged?.call();
        }
      },
      builder: (context, hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            scale: hovered ? 1.02 : 1,
            duration: motionMs(context, 160),
            curve: deskEaseOut,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: AnimatedContainer(
                duration: motionMs(context, 140),
                curve: Curves.ease,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(deskCorner),
                  border: Border.all(
                    color: hovered
                        ? scheme.onSurface.withValues(alpha: .6)
                        : scheme.onSurface.withValues(alpha: .09),
                    width: hovered ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(deskCorner),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Artwork(
                        show.backdrop,
                        color: show.color,
                        alignment: Alignment.topCenter,
                      ),
                      AnimatedContainer(
                        duration: motionMs(context, 140),
                        curve: Curves.ease,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: hovered ? .45 : 0),
                              Colors.black.withValues(alpha: .7),
                            ],
                            stops: const [.4, 1],
                          ),
                        ),
                      ),
                      Center(
                        child: AnimatedOpacity(
                          opacity: hovered ? 1 : .0,
                          duration: motionMs(context, 140),
                          child: const CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.white,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.black,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Text(
                          line,
                          style: text.labelLarge?.copyWith(color: Colors.white),
                        ),
                      ),
                      if (share > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _Progress(share),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            show.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            '${record.source}${record.dub ? ' · Dub' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A page's headline, its [note] under it and [actions] at the end, on the desktop's margin.
class DeskHeader extends StatelessWidget {
  const DeskHeader(this.title, {super.key, this.note, this.actions = const []});

  final String title;
  final String? note;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(deskMargin, 28, deskMargin, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.headlineMedium),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      note!,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Trending shows as wide pages: the banner across, the show on the left, ‹ › and dots to move through them. It turns
/// by itself every few seconds until the pointer is over it.
class DeskHero extends StatefulWidget {
  const DeskHero({super.key, required this.items, this.onChanged});

  final List items;
  final VoidCallback? onChanged;

  @override
  State<DeskHero> createState() => _DeskHeroState();
}

class _DeskHeroState extends State<DeskHero> {
  final controller = PageController();
  Timer? _turn;
  int page = 0;
  bool hovered = false;

  @override
  void initState() {
    super.initState();
    _turn = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!hovered && mounted && widget.items.length > 1) _go(page + 1);
    });
  }

  @override
  void dispose() {
    _turn?.cancel();
    controller.dispose();
    super.dispose();
  }

  void _go(int to) {
    final count = widget.items.length;
    controller.animateToPage(
      (to + count) % count,
      duration: const Duration(milliseconds: 380),
      curve: deskEaseInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * .52).clamp(
      340.0,
      480.0,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (context, i) =>
                  _HeroPage(widget.items[i], i + 1, widget.onChanged),
            ),
            if (widget.items.length > 1) ...[
              Positioned(
                // Beside the dots, clear of the text on the left.
                right: deskMargin - 12,
                bottom: 8,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      onPressed: () => _go(page - 1),
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    for (var i = 0; i < widget.items.length; i++)
                      GestureDetector(
                        onTap: () => _go(i),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: AnimatedContainer(
                            duration: motionMs(context, 250),
                            margin: const EdgeInsets.only(left: 6),
                            width: i == page ? 28 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == page
                                  ? scheme.primary
                                  : scheme.onSurface.withValues(alpha: .3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: () => _go(page + 1),
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeroPage extends StatelessWidget {
  const _HeroPage(this.media, this.rank, this.onChanged);

  final Map media;
  final int rank;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final show = Show(media);
    final description = plainText(show.description);
    final width = MediaQuery.sizeOf(context).width;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: width * .75,
          child: Artwork(
            show.backdrop,
            color: show.color,
            alignment: Alignment.topCenter,
            full: true,
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surface,
                scheme.surface,
                scheme.surface.withValues(alpha: 0),
              ],
              stops: const [0, .3, .78],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [scheme.surface.withValues(alpha: 0), scheme.surface],
              stops: const [.55, 1],
            ),
          ),
        ),
        Positioned(
          left: deskMargin,
          bottom: 36,
          width: (width * .42).clamp(320.0, 560.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(['Trending #$rank', ?airingLabel(media)].join(' · ')),
              const SizedBox(height: 10),
              Text(
                show.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.headlineMedium?.copyWith(
                  fontSize: 40,
                  height: 1.05,
                  letterSpacing: -.8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                [
                  if (show.score != null) '★ ${show.score}%',
                  mediaMeta(media, genres: 3),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => openDetails(
                      context,
                      media,
                      autoplay: true,
                      onBack: onChanged,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Watch now'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () =>
                        openDetails(context, media, onBack: onChanged),
                    child: const Text('Details'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A horizontal row's controller, and arrows over its ends while the pointer is over it: a mouse wheel only scrolls
/// the page. The row is built by [builder] with the controller.
class ScrollArrows extends StatefulWidget {
  const ScrollArrows({
    super.key,
    required this.builder,
    required this.arrowTop,
  });

  final Widget Function(ScrollController controller) builder;

  /// How far down the arrows sit.
  final double arrowTop;

  @override
  State<ScrollArrows> createState() => _ScrollArrowsState();
}

class _ScrollArrowsState extends State<ScrollArrows> {
  final controller = ScrollController();
  bool hovered = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    final c = controller;
    c.animateTo(
      (c.offset + direction * c.position.viewportDimension * .8).clamp(
        0.0,
        c.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 280),
      curve: deskEaseInOut,
    );
  }

  Widget _arrow(int direction, IconData icon) => Positioned(
    left: direction < 0 ? 4 : null,
    right: direction > 0 ? 4 : null,
    top: widget.arrowTop,
    child: IconButton.filledTonal(
      tooltip: direction < 0 ? 'Back' : 'Next',
      onPressed: () => _page(direction),
      icon: Icon(icon),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Stack(
        children: [
          widget.builder(c),
          if (hovered)
            ListenableBuilder(
              listenable: c,
              builder: (context, _) => Stack(
                children: [
                  if (c.hasClients && c.offset > 0)
                    _arrow(-1, Icons.chevron_left_rounded),
                  if (c.hasClients && c.offset < c.position.maxScrollExtent)
                    _arrow(1, Icons.chevron_right_rounded),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
