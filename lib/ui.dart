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

/// The cyan of the play triangle in the app icon.
const seed = Color(0xFF01C4FA);

/// Fidelity keeps the icon's vivid cyan as the accent instead of muting it.
final scheme = ColorScheme.fromSeed(
  seedColor: seed,
  brightness: Brightness.dark,
  dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
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
    focusColor: isTv ? scheme.primary.withValues(alpha: .28) : null,
    visualDensity: VisualDensity.standard,
    // A plain ripple in the text colour: Android's default sparkle flashes white and compiles a shader on first
    // use.
    splashFactory: InkRipple.splashFactory,
    splashColor: scheme.onSurface.withValues(alpha: .10),
    highlightColor: Colors.transparent,
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
      indicatorColor: scheme.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      labelType: NavigationRailLabelType.all,
    ),
    // Marquee chips: an outline ring, tinted with the accent while selected.
    // Chips are buttons too: the button corner.
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
      ),
      side: WidgetStateBorderSide.resolveWith(
        (s) => isTv && s.contains(WidgetState.focused)
            ? BorderSide.none
            : BorderSide(
                color: s.contains(WidgetState.selected)
                    ? scheme.primary
                    : scheme.outlineVariant,
              ),
      ),
      // On TV a focused chip turns solid, like a focused button.
      color: WidgetStateProperty.resolveWith(
        (s) => isTv && s.contains(WidgetState.focused)
            ? scheme.onSurface
            : s.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: .14)
            : Colors.transparent,
      ),
      labelStyle: TextStyle(
        color: WidgetStateColor.resolveWith(
          (s) => isTv && s.contains(WidgetState.focused)
              ? scheme.surface
              : s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurface,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      // Cards nest 8dp-cornered things 8dp in; ones that pad further set their own (see [nested]).
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(nested(8)),
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
    // Dialog actions sit 24dp in from the edge.
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(nested(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      // Its action button sits 8dp in from the edge.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(nested(8)),
      ),
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(
          nested(4),
        ), // its icon buttons, 4dp in
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(
          nested(4),
        ), // its icon buttons, 4dp in
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    // Nocturne's buttons. Primary (filled and tonal): an accent outline and label on a solid fill.
    // Secondary (outlined): a hairline outline. Ghost (text): the accent label alone.
    filledButtonTheme: FilledButtonThemeData(
      style: nocturneButton(
        scheme.primary,
        border: scheme.primary,
        fill: scheme.surface,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: nocturneButton(scheme.onSurface, border: hairline),
    ),
    textButtonTheme: TextButtonThemeData(style: nocturneButton(scheme.primary)),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.square(buttonHeight)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
      ).merge(tvButton),
    ),
    // Nocturne's segmented control: a hairline box, the chosen option ringed and labelled in the accent.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, buttonHeight)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.selected) ? scheme.primary : hairline,
          ),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: .12)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurface,
        ),
      ).merge(tvButton),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(buttonRadius),
      ),
    ),
  );
}

/// Marquee's key art: full-bleed, darkened a little under the status bar and fading into the page at its foot.
BoxDecoration get keyArtFade => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Dark enough by the lower third that the text set there reads over any art.
    colors: [
      scheme.surface.withValues(alpha: .45),
      scheme.surface.withValues(alpha: 0),
      scheme.surface.withValues(alpha: 0),
      scheme.surface.withValues(alpha: .75),
      scheme.surface,
    ],
    stops: const [0, .25, .4, .7, 1],
  ),
);

/// The accent's soft glow, behind the main action and live progress.
List<BoxShadow> accentGlow([double alpha = .35, double blur = 24]) => [
  BoxShadow(
    color: scheme.primary.withValues(alpha: alpha),
    blurRadius: blur,
  ),
];

/// A small uppercase line in the accent above a title: what's new, when it airs, which season.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    // Often over artwork: heavier, and shadowed so bright art behind it can't swallow it.
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      shadows: const [
        Shadow(color: Colors.black87, blurRadius: 8),
        Shadow(color: Colors.black54, blurRadius: 2),
      ],
    ),
  );
}

/// Fades and lifts its child in the first time it's built, [index] steps (of 40ms, up to 8) after the first, so
/// a row or grid arrives in a quick cascade. Still when animations are off.
class FadeIn extends StatelessWidget {
  const FadeIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = index.clamp(0, 8) * 40;
    final total = 320 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 16),
          child: child,
        ),
      ),
    );
  }
}

/// A light tick under the finger for a choice made (a tab, a chip); nothing on TV.
void selectionTick() {
  if (!isTv) HapticFeedback.selectionClick();
}

/// Phones: the navigation as a pill floating over the bottom of the page. The current page's item widens into a
/// tinted pill with its label; the others are icons with their label as a tooltip.
class FloatingNav extends StatelessWidget {
  const FloatingNav({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelect,
  });

  final List<(IconData icon, IconData selected, String label)> destinations;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      // The same 16dp from the sides and the bottom (the TV rail floats 16dp in too).
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      // A solid pill over the page scrolling behind it: no shadow, no border.
      // Its 48dp buttons sit 8dp in.
      child: Panel(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(nested(8)),
        ),
        child: Material(
          type: MaterialType.transparency,
          // 8dp from every edge of the pill: above and below the 48dp items, and before the first and after the last.
          child: Container(
            height: 64,
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final (i, (icon, selectedIcon, label))
                    in destinations.indexed)
                  Tooltip(
                    message: label,
                    child: Semantics(
                      selected: i == selected,
                      button: true,
                      label: label,
                      excludeSemantics: true,
                      // No ripple or press shade: the tab's own tint is the feedback.
                      child: InkWell(
                        customBorder: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(buttonRadius),
                        ),
                        splashFactory: NoSplash.splashFactory,
                        overlayColor: const WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        onTap: () {
                          if (i != selected) selectionTick();
                          onSelect(i);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          height: 48,
                          // 48dp squares, the selected one widening for its label.
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: ShapeDecoration(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(buttonRadius),
                            ),
                            color: i == selected
                                ? scheme.primary.withValues(alpha: .16)
                                : Colors.transparent,
                          ),
                          // The label slides out of the icon; the icon fills in with a small pop.
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: Row(
                              children: [
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  transitionBuilder: (child, a) =>
                                      ScaleTransition(
                                        scale: Tween(begin: .6, end: 1.0)
                                            .animate(
                                              CurvedAnimation(
                                                parent: a,
                                                curve: Curves.easeOutBack,
                                              ),
                                            ),
                                        child: FadeTransition(
                                          opacity: a,
                                          child: child,
                                        ),
                                      ),
                                  child: Icon(
                                    i == selected ? selectedIcon : icon,
                                    key: ValueKey(i == selected),
                                    color: i == selected
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (i == selected) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    label,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(color: scheme.primary),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pushes [route] and completes once it has finished animating away, so whatever the caller reloads on return
/// (lists, a refresh) doesn't rebuild the page underneath while the back animation is still running.
Future<T?> pushSettled<T>(BuildContext context, Route<T> route) async {
  final result = await Navigator.push(context, route);
  final animation = route is ModalRoute<T> ? route.animation : null;
  if (animation != null && !animation.isDismissed) {
    final gone = Completer<void>();
    animation.addStatusListener((s) {
      if (s.isDismissed && !gone.isCompleted) gone.complete();
    });
    await gone.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  }
  return result;
}

/// A solid surface clipped to [shape]: the one look for everything that floats over content (the navigation,
/// sheets, dialogs, menus).
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.shape = const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radiusLarge)),
    ),
    this.color,
  });

  final Widget child;
  final ShapeBorder shape;

  /// Defaults to the raised surface.
  final Color? color;

  // A Material, not just a coloured box: rows inside draw their focus highlight and ripples on it (on a box
  // they'd be painted underneath and never show). Clipped, so nothing (a highlight wider than the rail) spills out.
  @override
  Widget build(BuildContext context) => Material(
    color: color ?? scheme.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    shape: shape,
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// The main action on a screen (play, continue, watch): the accent's glow around the button.
class AccentAction extends StatelessWidget {
  const AccentAction({super.key, required this.child});

  final Widget child;

  static final _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(buttonRadius),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(shape: _shape, shadows: accentGlow(.25)),
    child: child,
  );
}

/// Lifts a floating button on a page under [FloatingNav] clear of it: its scaffold only keeps it off the system
/// bar, while the pill floats higher. The scaffold hides the padding from its button, so [page] is a context
/// from outside it (the page's own).
class ClearOfNav extends StatelessWidget {
  ClearOfNav({super.key, required BuildContext page, required this.child})
    : lift = _lift(MediaQuery.of(page));

  final double lift;
  final Widget child;

  /// The page's bottom padding is the pill's height, system bar included; the scaffold already adds the bar.
  static double _lift(MediaQueryData media) {
    final lift = media.padding.bottom - media.viewPadding.bottom;
    return lift > 0 ? lift : 0;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: lift),
    child: child,
  );
}

/// Every dialog: a solid panel like the sheets and the navigation, 32dp corners (its buttons sit 24dp in). Give
/// it a [title], [content] and [actions] like an AlertDialog, or a [child] to fill it.
class PanelDialog extends StatelessWidget {
  const PanelDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.child,
  });

  final Widget? title, content, child;
  final List<Widget> actions;

  static final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(nested(24)),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: shape,
      child: Panel(
        shape: shape,
        color: scheme.surfaceContainerHigh,
        child:
            child ??
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    DefaultTextStyle.merge(
                      style: text.titleLarge,
                      child: title!,
                    ),
                  if (content != null) ...[
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(
                        child: DefaultTextStyle.merge(
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          child: content!,
                        ),
                      ),
                    ),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
      ),
    );
  }
}

/// One choice in a [MoreMenu].
typedef MenuAction = ({
  IconData icon,
  String label,
  VoidCallback onTap,
  bool destructive,
});

/// ⋮ that opens its [actions] as a sheet (a panel on TV), like every other list of choices. Nothing
/// when there are none.
class MoreMenu extends StatelessWidget {
  const MoreMenu(this.actions, {super.key, this.title});

  final List<MenuAction> actions;

  /// What they act on, heading the sheet.
  final String? title;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert_rounded),
      onPressed: () async {
        final picked = await showSheet<VoidCallback>(
          context,
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) sheetTitle(context, title!),
                for (final (i, a) in actions.indexed)
                  a.destructive
                      ? DestructiveTile(
                          autofocus: isTv && i == 0,
                          icon: a.icon,
                          title: a.label,
                          onTap: () => Navigator.pop(context, a.onTap),
                        )
                      : ListTile(
                          autofocus: isTv && i == 0,
                          leading: Icon(a.icon),
                          title: Text(a.label),
                          onTap: () => Navigator.pop(context, a.onTap),
                        ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        picked?.call();
      },
    );
  }
}

/// Anything that deletes or removes: the error colour, in the primary button's form.
ButtonStyle get destructiveButton => nocturneButton(
  scheme.error,
  border: scheme.error,
  fill: scheme.error.withValues(alpha: .12),
);

/// Asks before deleting or removing something; true when confirmed. The action is red, and on TV focus starts
/// on Cancel so a stray OK press can't delete.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => PanelDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            autofocus: isTv,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructiveButton,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// A row that deletes or removes: its icon and title in the error colour.
class DestructiveTile extends StatelessWidget {
  const DestructiveTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => ListTile(
    autofocus: autofocus,
    iconColor: scheme.error,
    textColor: scheme.error,
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null
        ? null
        : DefaultTextStyle.merge(
            style: TextStyle(color: scheme.onSurfaceVariant),
            child: subtitle!,
          ),
    onTap: onTap,
  );
}

/// Corner radii nest: an outer corner is the inner one plus the space between them, so the curves run parallel.
/// Buttons have [buttonRadius]; a container holding one [padding] in from its edge gets [nested].
const buttonRadius = radiusMedium;

/// Every button is this tall: text, icon, segmented and the main play action alike (and the navigation items).
/// TV's are taller, so a two-line play button sits level with the rest of its row.
double get buttonHeight => isTv ? 56 : 48;

/// The corner scale. Small: badges and text placeholders. Medium: buttons, small thumbnails and stills. Large:
/// posters, tiles, and cards without buttons in them. Chips, the navigation and the search field are pills; any
/// container holding one of these takes its corner from [nested].
const radiusSmall = 4.0, radiusMedium = 8.0, radiusLarge = 12.0;
double nested(double padding, [double inner = buttonRadius]) => inner + padding;

/// Nocturne's divider: the text colour at 16%.
Color get hairline => scheme.onSurface.withValues(alpha: .16);

/// A Nocturne button: 8dp corners, a 1dp outline in [border] (none when null), a [fill] behind, and pressing
/// tints it with its own colour. Disabled, it fades to 45%. On TV a focused button turns solid (light on dark
/// becomes dark on light), readable from across the room.
ButtonStyle nocturneButton(Color color, {Color? border, Color? fill}) {
  bool tvFocused(Set<WidgetState> s) => isTv && s.contains(WidgetState.focused);
  Color faded(Set<WidgetState> s, Color c) =>
      s.contains(WidgetState.disabled) ? c.withValues(alpha: c.a * .45) : c;
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(64, buttonHeight)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)),
    ),
    textStyle: WidgetStatePropertyAll(
      typeScale.labelLarge?.copyWith(fontWeight: FontWeight.w500),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => tvFocused(s) ? scheme.surface : faded(s, color),
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (s) => tvFocused(s) ? scheme.surface : faded(s, color),
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => tvFocused(s) ? scheme.onSurface : fill ?? Colors.transparent,
    ),
    side: WidgetStateProperty.resolveWith(
      (s) => border == null || tvFocused(s)
          ? BorderSide.none
          : BorderSide(color: faded(s, border)),
    ),
    overlayColor: WidgetStateProperty.resolveWith(
      (s) => tvFocused(s)
          ? Colors.transparent
          : s.contains(WidgetState.pressed)
          ? color.withValues(alpha: .22)
          : s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
          ? color.withValues(alpha: .12)
          : null,
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
    this.radius = radiusLarge,
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
      color: scheme.surfaceContainerHighest, // solid, over any art
      borderRadius: BorderRadius.circular(
        radiusSmall,
      ), // 8dp inside large posters
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
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
    this.onTap,
    this.onLongPress,
    this.onBack,
    this.autofocus = false,
    this.selected,
  });

  final Map media;
  final String? subtitle;

  /// Instead of opening the show (while picking several, say).
  final VoidCallback? onTap;
  final VoidCallback? onLongPress, onBack;
  final bool autofocus;

  /// Picking several: whether this one is picked (a check on the card); null when not picking.
  final bool? selected;

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
      onTap: onTap ?? () => openDetails(context, media, onBack: onBack),
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
            if (score != null && !isTv && selected == null)
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
                child: Container(
                  height: 3,
                  color: Colors.black54,
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: (progress / total).clamp(0.0, 1.0).toDouble(),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        boxShadow: accentGlow(.8, 6),
                      ),
                    ),
                  ),
                ),
              ),
            if (selected case final picked?) ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: picked
                      ? scheme.primary.withValues(alpha: .22)
                      : Colors.black.withValues(alpha: .15),
                  border: picked
                      ? Border.all(color: scheme.primary, width: 3)
                      : null,
                  borderRadius: BorderRadius.circular(radiusLarge),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, a) =>
                      ScaleTransition(scale: a, child: child),
                  child: Icon(
                    picked
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    key: ValueKey(picked),
                    color: picked ? scheme.primary : Colors.white,
                    shadows: const [Shadow(blurRadius: 6)],
                  ),
                ),
              ),
            ],
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
          style: text.bodyMedium?.copyWith(height: 1.25),
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
                  child: FadeIn(
                    index: i,
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
              child: const Skeleton(
                width: 150,
                height: 18,
                radius: radiusSmall,
              ),
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

/// Every grid of posters (search, My list): two large ones across a phone (Marquee), the 5-card width on TV.
/// Tiles of other things in a grid (genres) take [gridTileExtent] so their columns line up with these.
SliverGridDelegate get posterGrid => SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: gridTileExtent,
  childAspectRatio: isTv ? 2 / 3 : .52,
  crossAxisSpacing: gutter,
  mainAxisSpacing: isTv ? gutter : 16,
);

double get gridTileExtent => isTv ? posterWidth + 16 : 200;

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
  height: .5,
  (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sheetTitle(context, title),
        Flexible(
          // Plain rows, not a radio group: a radio group takes the arrow keys as picking the next option, so
          // on TV the D-pad changed the choice. Here it only moves the focus, and OK chooses.
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final MapEntry(:key, :value) in options.entries)
                  ScrollIntoViewOnFocus(
                    child: ListTile(
                      autofocus: key == current,
                      selected: key == current,
                      leading: Icon(
                        key == current
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                      ),
                      title: Text(value),
                      onTap: () => Navigator.pop(context, key),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Scrolls its child to the middle of the list whenever it (or something in it) takes focus, so the row a remote
/// is on is always in view, including the one focused when a list opens.
class ScrollIntoViewOnFocus extends StatelessWidget {
  const ScrollIntoViewOnFocus({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused) {
        Scrollable.ensureVisible(
          context,
          alignment: .5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    },
    child: child,
  );
}

/// Picks any of [options]; the new selection when Done is pressed, null when dismissed.
Future<Set<String>?> pickMany(
  BuildContext context,
  String title,
  List<String> options,
  Set<String> selected,
) => showSheet<Set<String>>(context, height: .5, (context) {
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
                    ScrollIntoViewOnFocus(
                      child: CheckboxListTile(
                        autofocus: i == 0,
                        value: picked.contains(option),
                        title: Text(option),
                        onChanged: (on) => setState(
                          () => on == true
                              ? picked.add(option)
                              : picked.remove(option),
                        ),
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
