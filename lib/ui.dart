import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'anilist.dart';
import 'details.dart';
import 'states.dart';
import 'tv.dart';

/// The design system, from the Android design guides: Material 3 on phones (tonal surfaces, the M3 type scale,
/// 16dp margins, 48dp touch targets), and on TV the Google TV rules: 48dp side / 24dp top and bottom overscan,
/// cards that scale 1.1× with a border and glow when focused, and buttons that invert on focus.

const seed = Color(0xFF8B5CF6);

final scheme = ColorScheme.fromSeed(
  seedColor: seed,
  brightness: Brightness.dark,
);

/// Side margin: 16dp on phones, the TV overscan margin on TV.
double get side => isTv ? tvMargin : 16;

/// Space between cards in a row or grid: 12dp on phones, the TV grid's 20dp gutter on TV.
double get gutter => isTv ? 20 : 12;

/// Poster width in rows: three and a bit across a phone, the TV layout's 5-card width on TV.
double get posterWidth => isTv ? 124 : 116;

/// Four sizes and two weights, and nothing else: 28 for a screen's headline, 18 for titles, 14 for body text
/// and labels, 12 for captions; regular for reading, semibold for anything that names or labels.
final typeScale = () {
  // Tracking by size: large text reads loose, so it tightens; small text opens up a touch to stay legible.
  TextStyle style(double size, FontWeight weight, double height) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: switch (size) {
      >= 28 => -.5,
      >= 18 => -.2,
      <= 12 => .2,
      _ => 0,
    },
    color: scheme.onSurface,
  );
  const regular = FontWeight.w400, semibold = FontWeight.w600;
  final headline = style(28, semibold, 1.15);
  final title = style(18, semibold, 1.3);
  return TextTheme(
    displayLarge: headline,
    displayMedium: headline,
    displaySmall: headline,
    headlineLarge: headline,
    headlineMedium: headline,
    headlineSmall: headline,
    titleLarge: title,
    titleMedium: title,
    titleSmall: style(14, semibold, 1.3),
    bodyLarge: style(14, regular, 1.5),
    bodyMedium: style(14, regular, 1.5),
    bodySmall: style(12, regular, 1.4),
    labelLarge: style(14, semibold, 1.3),
    labelMedium: style(12, semibold, 1.3),
    labelSmall: style(12, semibold, 1.3),
  );
}();

ThemeData buildTheme() {
  final text = typeScale;
  // TV: a focused button turns solid (light on dark becomes dark on light), readable from across the room.
  // Unfocused states resolve to null, which falls through to each button's own defaults.
  final tvButton = !isTv
      ? null
      : ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? scheme.onSurface : null,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? scheme.surface : null,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? scheme.surface : null,
          ),
          overlayColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? Colors.transparent : null,
          ),
        );
  return ThemeData(
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    // Other focusable things (list rows, chips, switches) get a clear highlight on TV.
    focusColor: isTv ? scheme.onSurface.withValues(alpha: .22) : null,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      // On TV a focused chip turns solid, like a focused button.
      color: WidgetStateProperty.resolveWith(
        (s) => isTv && s.contains(WidgetState.focused)
            ? scheme.onSurface
            : s.contains(WidgetState.selected)
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
      ),
      labelStyle: TextStyle(
        color: WidgetStateColor.resolveWith(
          (s) => isTv && s.contains(WidgetState.focused)
              ? scheme.surface
              : s.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurface,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: side),
      iconColor: scheme.onSurfaceVariant,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: tvButton),
    outlinedButtonTheme: OutlinedButtonThemeData(style: tvButton),
    textButtonTheme: TextButtonThemeData(style: tvButton),
    iconButtonTheme: IconButtonThemeData(style: tvButton),
    segmentedButtonTheme: SegmentedButtonThemeData(style: tvButton),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
    ),
  );
}

Color? hexColor(String? hex) => hex == null || hex.length != 7
    ? null
    : Color(int.parse('FF${hex.substring(1)}', radix: 16));

/// A network image that fades in over its show's colour, decoded at the size it's shown (a 1080p still decoded
/// whole is ~8 MB, and a row of them thrashes the image cache). [full] decodes as-is, for backdrops cropped to
/// fill a wide box.
class Artwork extends StatelessWidget {
  const Artwork(
    this.url, {
    super.key,
    this.color,
    this.alignment = Alignment.center,
    this.full = false,
    this.placeholder,
  });

  final String? url;
  final String? color;
  final Alignment alignment;
  final bool full;

  /// Shown behind the image, and alone when there is none.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            hexColor(color)?.withValues(alpha: .25) ??
            scheme.surfaceContainerHigh,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?placeholder,
          if (url != null)
            LayoutBuilder(
              builder: (context, box) => Image.network(
                url,
                fit: BoxFit.cover,
                alignment: alignment,
                cacheWidth: full || !box.maxWidth.isFinite
                    ? null
                    : (box.maxWidth * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                frameBuilder: (context, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 250),
                        child: child,
                      ),
                errorBuilder: (_, _, _) => const SizedBox(),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tappable, focusable picture. On TV it scales 1.1× with a white border and a glow in the show's colour while
/// focused (the Google TV card focus state); on phones it dips slightly while pressed.
class FocusCard extends StatefulWidget {
  const FocusCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onFocus,
    this.glow,
    this.radius = 12,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap, onLongPress, onFocus;
  final Color? glow;
  final double radius;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;

  @override
  State<FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<FocusCard> {
  bool focused = false, pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: AnimatedScale(
        scale: still
            ? 1
            : focused
            ? 1.1
            : pressed
            ? .96
            : 1,
        duration: Duration(milliseconds: pressed ? 90 : 180),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: (widget.glow ?? scheme.primary).withValues(
                        alpha: .55,
                      ),
                      blurRadius: 24,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: focused ? Border.all(color: Colors.white, width: 3) : null,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                widget.child,
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      focusNode: widget.focusNode,
                      autofocus: widget.autofocus,
                      focusColor: Colors.transparent,
                      onTap: widget.onTap,
                      onLongPress: widget.onLongPress == null
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              widget.onLongPress!();
                            },
                      onHighlightChanged: (v) => setState(() => pressed = v),
                      onFocusChange: (v) {
                        setState(() => focused = v);
                        if (v) widget.onFocus?.call();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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

/// A small label over artwork: the score, or when the next episode airs.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, this.iconColor});

  const Pill.score(int score, {super.key})
    : label = '$score%',
      icon = Icons.star_rounded,
      iconColor = const Color(0xFFFFC857);

  final String label;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .72),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: iconColor ?? scheme.primary),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Format, year, episode count and genres, joined for a line of metadata.
String mediaMeta(Map media, {int genres = 2}) => [
  media['format']?.toString().replaceAll('_', ' '),
  media['seasonYear'],
  if (Show(media).episodes case final n?) '$n eps',
  ...Show(media).genres.take(genres),
].whereType<Object>().join(' · ');

/// A description without AniList's HTML.
String plainText(String? html) =>
    (html ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();

Timer? _backdropDelay;

/// A show's poster (2:3) with its title under it on phones. On TV the title shows in the immersive backdrop
/// above the rows instead, so rows stay compact, and focus rests a moment before the backdrop changes.
class PosterCard extends StatelessWidget {
  const PosterCard(
    this.media, {
    super.key,
    this.subtitle,
    this.onLongPress,
    this.onBack,
    this.autofocus = false,
  });

  final Map media;
  final String? subtitle;
  final VoidCallback? onLongPress, onBack;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final show = Show(media);
    final progress = show.inList ? show.progress : null;
    final total = show.aired;
    final airing = airingLabel(media);
    final line =
        subtitle ??
        (progress == null
            ? null
            : 'EP $progress${total == null ? '' : ' / $total'}');
    final score = show.score;
    final card = FocusCard(
      autofocus: autofocus,
      glow: hexColor(show.color),
      semanticLabel: [titleOf(media), ?line].join(', '),
      onTap: () => openDetails(context, media, onBack: onBack),
      onLongPress: onLongPress,
      onFocus: () {
        _backdropDelay?.cancel();
        _backdropDelay = Timer(
          const Duration(milliseconds: 200),
          () => focusedMedia.value = media,
        );
      },
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(show.cover, color: show.color),
            if (score != null && !isTv)
              Positioned(top: 8, right: 8, child: Pill.score(score)),
            // TV cards have no text under them, so what the row says about the show goes on the card.
            if (isTv && subtitle != null)
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Pill(subtitle!),
                ),
              ),
            if (airing != null)
              Positioned(
                left: 8,
                bottom: 8,
                child: Pill(airing, icon: Icons.schedule_rounded),
              ),
            if (progress != null && total != null && total > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: (progress / total).clamp(0.0, 1.0).toDouble(),
                  minHeight: 3,
                  backgroundColor: Colors.black54,
                ),
              ),
          ],
        ),
      ),
    );
    if (isTv) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        const SizedBox(height: 8),
        Text(
          titleOf(media),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.labelLarge?.copyWith(height: 1.25),
        ),
        if (line != null)
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// A section title, with an optional action ("See all") at its end on phones.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(side, isTv ? 20 : 24, side - 8, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isTv
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.titleLarge,
          ),
        ),
        ?action,
      ],
    ),
  );
}

/// A titled row of posters. On TV, "See all" is the row's last card, where the D-pad can reach it.
class MediaRow extends StatelessWidget {
  const MediaRow(
    this.title,
    this.items, {
    super.key,
    this.subtitles,
    this.onLongPress,
    this.onSeeAll,
    this.onBack,
    this.autofocus = false,
  });

  final String title;
  final List items;
  final List<String>? subtitles;
  final ValueChanged<int>? onLongPress;
  final VoidCallback? onSeeAll, onBack;

  /// TV: the first card takes focus when the page opens.
  final bool autofocus;

  /// Poster height plus room for the title lines under it on phones, or for the focus scale on TV.
  static double get height =>
      posterWidth * 3 / 2 + (isTv ? posterWidth * .15 : 58);

  @override
  Widget build(BuildContext context) {
    final count = items.length + (isTv && onSeeAll != null ? 1 : 0);
    return ScrollAnchor(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title,
            action: onSeeAll == null || isTv
                ? null
                : TextButton(onPressed: onSeeAll, child: const Text('See all')),
          ),
          SizedBox(
            height: height,
            child: TvRow(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // Clipped to the row, which leaves room around each card for it to grow when focused.
                padding: EdgeInsets.symmetric(
                  horizontal: side,
                  vertical: isTv ? posterWidth * .075 : 0,
                ),
                itemCount: count,
                separatorBuilder: (_, _) => SizedBox(width: gutter),
                itemBuilder: (context, i) => SizedBox(
                  width: posterWidth,
                  child: i == items.length
                      ? _SeeAllCard(onSeeAll!)
                      : PosterCard(
                          items[i],
                          autofocus: autofocus && i == 0,
                          onBack: onBack,
                          subtitle: subtitles?[i],
                          onLongPress: onLongPress == null
                              ? null
                              : () => onLongPress!(i),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeeAllCard extends StatelessWidget {
  const _SeeAllCard(this.onTap);

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FocusCard(
    onTap: onTap,
    semanticLabel: 'See all',
    child: AspectRatio(
      aspectRatio: 2 / 3,
      child: ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.arrow_forward_rounded, color: scheme.primary),
            const SizedBox(height: 8),
            Text('See all', style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    ),
  );
}

/// A row's placeholder while it loads.
class RowSkeleton extends StatelessWidget {
  const RowSkeleton({super.key, this.title});

  final String? title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title == null
          ? Padding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 12),
              child: const Skeleton(width: 150, height: 18, radius: 6),
            )
          : SectionHeader(title!),
      SizedBox(
        height: MediaRow.height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: side),
          itemCount: 6,
          separatorBuilder: (_, _) => SizedBox(width: gutter),
          itemBuilder: (_, _) => SizedBox(
            width: posterWidth,
            child: const Align(
              alignment: Alignment.topCenter,
              child: AspectRatio(aspectRatio: 2 / 3, child: Skeleton()),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Cards in a grid for search results: as many 2:3 posters across as fit.
SliverGridDelegate get posterGrid => SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: isTv ? posterWidth + 16 : 140,
  childAspectRatio: isTv ? 2 / 3 : .5,
  crossAxisSpacing: gutter,
  mainAxisSpacing: isTv ? gutter : 16,
);

/// A sheet on phones, a centred panel on TV; see [showSheet].
Widget sheetTitle(BuildContext context, String title, {String? subtitle}) =>
    Padding(
      padding: EdgeInsets.fromLTRB(24, isTv ? 0 : 4, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );

/// Picks one of [options] from a short list (a bottom sheet on phones, a panel on TV, where Back closes it and
/// focus starts on the current choice); null when dismissed.
Future<T?> pickOne<T>(
  BuildContext context,
  String title,
  Map<T, String> options,
  T current,
) => showSheet<T>(
  context,
  scrollControlled: true,
  (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sheetTitle(context, title),
        Flexible(
          child: SingleChildScrollView(
            child: RadioGroup<T>(
              groupValue: current,
              onChanged: (v) => Navigator.pop(context, v),
              child: Column(
                children: [
                  for (final MapEntry(:key, :value) in options.entries)
                    RadioListTile<T>(
                      autofocus: key == current,
                      value: key,
                      title: Text(value),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Picks any of [options]; the new selection when Done is pressed, null when dismissed.
Future<Set<String>?> pickMany(
  BuildContext context,
  String title,
  List<String> options,
  Set<String> selected,
) => showSheet<Set<String>>(context, scrollControlled: true, (context) {
  final picked = {...selected};
  return StatefulBuilder(
    builder: (context, setState) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sheetTitle(context, title),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final (i, option) in options.indexed)
                    CheckboxListTile(
                      autofocus: i == 0,
                      value: picked.contains(option),
                      title: Text(option),
                      onChanged: (on) => setState(
                        () => on == true
                            ? picked.add(option)
                            : picked.remove(option),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => setState(picked.clear),
                  child: const Text('Clear'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(context, picked),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
});
