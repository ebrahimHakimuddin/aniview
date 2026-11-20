part of '../settings.dart';

class _HomeSectionsScreen extends StatefulWidget {
  const _HomeSectionsScreen();

  @override
  State<_HomeSectionsScreen> createState() => _HomeSectionsScreenState();
}

class _HomeSectionsScreenState extends State<_HomeSectionsScreen> {
  final sections = Settings.homeSections;

  void _save() => setState(() => Settings.homeSections = sections);

  /// Home with nothing on it would be a blank page, so leaving needs at least one section on.
  bool get _anyShown => sections.any((s) => s.$2);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _anyShown,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) showError(context, 'Turn on at least one section for Home');
    },
    child: _page(context),
  );

  Widget _page(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Home sections'),
      actions: [
        TextButton(
          onPressed: () {
            sections
              ..clear()
              ..addAll([for (final s in HomeSection.values) (s, s.byDefault)]);
            _save();
          },
          child: const Text('Reset'),
        ),
      ],
    ),
    body: ReorderableListView(
      // The handle drags straight away; the rest of the row still scrolls and toggles.
      buildDefaultDragHandles: false,
      padding: EdgeInsets.only(
        bottom: 32 + MediaQuery.paddingOf(context).bottom,
      ),
      onReorderStart: (_) => HapticFeedback.selectionClick(),
      onReorderItem: (from, to) {
        sections.insert(to, sections.removeAt(from));
        HapticFeedback.lightImpact();
        _save();
      },
      proxyDecorator: (child, _, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(animation.value);
          return Transform.scale(
            scale: 1 + .03 * t,
            child: Material(
              color: Color.lerp(
                Colors.transparent,
                scheme.surfaceContainerHighest,
                t,
              ),
              elevation: 12 * t,
              shadowColor: Colors.black,
              borderRadius: BorderRadius.circular(
                nested(8),
              ), // a card, like the rest
              child: child,
            ),
          );
        },
        child: child,
      ),
      children: [
        for (final (i, (section, shown)) in sections.indexed)
          SwitchListTile(
            key: ValueKey(section),
            // Dragging needs touch; a remote moves rows with buttons (on a TV box in the phone layout too).
            secondary: !remoteOnly
                ? ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      // A roomier target than the bare icon.
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_indicator_rounded),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (icon, to, label) in [
                        (Icons.arrow_upward_rounded, i - 1, 'Move up'),
                        (Icons.arrow_downward_rounded, i + 1, 'Move down'),
                      ])
                        IconButton(
                          tooltip: label,
                          icon: Icon(icon),
                          // Kept enabled at the ends: disabling the focused button would drop the remote's focus.
                          color: to < 0 || to >= sections.length
                              ? scheme.onSurface.withValues(alpha: .3)
                              : null,
                          onPressed: () {
                            if (to < 0 || to >= sections.length) return;
                            sections.insert(to, sections.removeAt(i));
                            _save();
                          },
                        ),
                    ],
                  ),
            title: Text(section.label),
            subtitle: Text(section.description),
            value: shown,
            onChanged: (v) {
              sections[i] = (section, v);
              _save();
            },
          ),
      ],
    ),
  );
}
