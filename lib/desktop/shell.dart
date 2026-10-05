import 'package:flutter/material.dart';

import '../anilist.dart';
import '../changelog.dart';
import '../desktop.dart';
import '../home_feed.dart';
import '../tracker.dart';
import '../ui.dart';
import '../settings.dart' show SettingsScreen;
import 'downloads.dart';
import 'home.dart';
import 'motion.dart';
import 'picks.dart';
import 'my_list.dart';
import 'profile.dart';
import 'search.dart';
import 'search_box.dart';
import 'schedule.dart';
import 'widgets.dart';

enum DeskSection {
  home(Icons.home_outlined, Icons.home_rounded, 'Home'),
  schedule(
    Icons.calendar_today_outlined,
    Icons.calendar_today_rounded,
    'Schedule',
  ),
  list(Icons.bookmarks_outlined, Icons.bookmarks_rounded, 'My list'),
  downloads(
    Icons.download_for_offline_outlined,
    Icons.download_for_offline_rounded,
    'Downloads',
  ),
  settings(Icons.settings_outlined, Icons.settings_rounded, 'Settings'),

  /// Not in the sidebar: the results of what's typed in the top bar.
  search(Icons.search_rounded, Icons.search_rounded, 'Search');

  const DeskSection(this.icon, this.selected, this.label);
  final IconData icon, selected;
  final String label;
}

/// What the top bar's search box asks for, and the filters a "See all" or a genre brings.
class DeskSearchRequest {
  const DeskSearchRequest(this.text, [this.filters = const SearchFilters()]);

  final String text;
  final SearchFilters filters;
}

/// The desktop app: a sidebar of the places, a top bar with search and the account, and the page itself. Every place
/// keeps its own stack of pages (a show opened from Home goes back to Home), under one back button.
class DeskShell extends StatefulWidget {
  const DeskShell({
    super.key,
    required this.feed,
    required this.onRefresh,
    required this.onReload,
    required this.onSignIn,
    required this.actions,
  });

  final HomeFeed feed;
  final Future<void> Function() onRefresh;
  final void Function({bool force, bool checkStale}) onReload;
  final VoidCallback onSignIn;

  /// The top bar's buttons: random, new episodes, the TV remote.
  final List<Widget> actions;

  @override
  State<DeskShell> createState() => _DeskShellState();
}

class _DeskShellState extends State<DeskShell> {
  static const _sidebar = 232.0, _rail = 76.0;

  final _keys = {
    for (final s in DeskSection.values) s: GlobalKey<NavigatorState>(),
  };
  final _visited = {DeskSection.home};
  final _search = ValueNotifier(const DeskSearchRequest(''));
  final _field = TextEditingController();
  final _fieldFocus = FocusNode();
  // One each: an observer can watch only one Navigator.
  late final _observers = {
    for (final s in DeskSection.values)
      s: _Changes(
        onChange: () {
          if (mounted) setState(() {});
        },
        onTitle: (title, pushed) {
          final stack = _pageTitles[s]!;
          pushed ? stack.add(title) : stack.remove(title);
          if (s == section) _retitle();
        },
      ),
  };

  /// The titles of the pages open in each place (a show's name), the last one being what the window says.
  final _pageTitles = {for (final s in DeskSection.values) s: <String>[]};

  void _retitle() =>
      setWindowTitle(_pageTitles[section]!.lastOrNull ?? section.label);

  DeskSection section = DeskSection.home, _before = DeskSection.home;

  NavigatorState? get _nav => _keys[section]!.currentState;

  @override
  void initState() {
    super.initState();
    onDesktopFind = () => _fieldFocus.requestFocus();
    desktopBack = _back;
    onDesktopSearch = _openSearch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retitle();
      if (mounted) maybeShowWhatsNew(context);
    });
  }

  @override
  void dispose() {
    onDesktopFind = null;
    desktopBack = null;
    onDesktopSearch = null;
    _search.dispose();
    _field.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// Back in the page you're on, else out of Search to where you were; false when there's nowhere to go.
  bool _back() {
    final nav = _nav;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    if (section == DeskSection.search) {
      _select(_before);
      return true;
    }
    return false;
  }

  void _select(DeskSection to) {
    deskPicks.clear();
    if (to != DeskSection.search) _fieldFocus.unfocus();
    if (to == section) {
      // The place you're in, again: back to its first page.
      _nav?.popUntil((r) => r.isFirst);
      return;
    }
    if (const [
      DeskSection.home,
      DeskSection.schedule,
      DeskSection.list,
    ].contains(to)) {
      widget.onReload(checkStale: true);
    }
    // Settings may have changed the sign-in or the home sections.
    if (section == DeskSection.settings) widget.onRefresh();
    setState(() {
      if (section != DeskSection.search) _before = section;
      section = to;
      _visited.add(to);
    });
    _retitle();
  }

  /// Shows Search with [filters] and [text] (put in the box when it isn't there already).
  void _openSearch(SearchFilters filters, [String text = '']) {
    if (_field.text != text) _field.text = text;
    _ask(text, filters);
  }

  void _ask(String text, SearchFilters filters) {
    _search.value = DeskSearchRequest(text, filters);
    if (section != DeskSection.search) {
      _select(DeskSection.search);
    } else {
      _nav?.popUntil((r) => r.isFirst);
    }
  }

  Widget _page(DeskSection s) => switch (s) {
    DeskSection.home => DeskHome(
      widget.feed,
      onRefresh: widget.onRefresh,
      onReload: widget.onReload,
      onSignIn: widget.onSignIn,
    ),
    DeskSection.schedule => DeskSchedule(
      widget.feed,
      onRefresh: widget.onRefresh,
      onReload: widget.onReload,
    ),
    DeskSection.list => DeskMyList(
      widget.feed,
      onReload: widget.onReload,
      onSignIn: widget.onSignIn,
    ),
    DeskSection.downloads => DeskDownloads(
      onBrowse: () => _select(DeskSection.home),
    ),
    DeskSection.settings => const SettingsScreen(),
    DeskSection.search => DeskSearch(_search, onReload: widget.onReload),
  };

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 1000;
    return Scaffold(
      // Over the page's foot while shows are picked (Home's rows, Search).
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: DeskPickBar(
        onChanged: () => widget.onReload(force: true),
      ),
      body: Row(
        children: [
          _Sidebar(
            width: compact ? _rail : _sidebar,
            compact: compact,
            selected: section,
            feed: widget.feed,
            onSelect: _select,
            onSignIn: widget.onSignIn,
            onProfile: () {
              if (section == DeskSection.search) return;
              _nav?.push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(
                    name: 'profile',
                    arguments: 'Profile',
                  ),
                  builder: (_) => DeskProfile(
                    widget.feed,
                    onRefresh: widget.onRefresh,
                    onSignedOut: () {
                      _nav?.popUntil((r) => r.isFirst);
                      widget.onRefresh();
                    },
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  controller: _field,
                  focus: _fieldFocus,
                  canGoBack:
                      (_nav?.canPop() ?? false) ||
                      section == DeskSection.search,
                  onBack: _back,
                  onSearch: (text) => _ask(
                    text,
                    section == DeskSection.search
                        ? _search.value.filters
                        : const SearchFilters(),
                  ),
                  onRefresh: widget.onRefresh,
                  actions: widget.actions,
                ),
                Expanded(
                  // Switching place is the app's most-used move, so it's instant: no fade between them.
                  child: IndexedStack(
                    index: DeskSection.values.indexOf(section),
                    children: [
                      for (final s in DeskSection.values)
                        ExcludeFocus(
                          excluding: s != section,
                          child: TickerMode(
                            enabled: s == section,
                            child: _visited.contains(s)
                                ? Navigator(
                                    key: _keys[s],
                                    observers: [_observers[s]!],
                                    onGenerateRoute: (_) => PageRouteBuilder(
                                      pageBuilder: (_, _, _) =>
                                          Material(child: _page(s)),
                                      transitionDuration: Duration.zero,
                                    ),
                                  )
                                : const SizedBox(),
                          ),
                        ),
                    ],
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

/// Tells the shell when any of its stacks pushed or popped, so the back button follows.
class _Changes extends NavigatorObserver {
  _Changes({required this.onChange, required this.onTitle});

  final VoidCallback onChange;

  /// A page that names itself (route arguments: a String) came or went.
  final void Function(String title, bool pushed) onTitle;

  void _later() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange());

  void _title(Route route, bool pushed) {
    if (route.settings.arguments case final String title
        when route.settings.name != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onTitle(title, pushed),
      );
    }
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    _title(route, true);
    _later();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _title(route, false);
    _later();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    _title(route, false);
    _later();
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.width,
    required this.compact,
    required this.selected,
    required this.feed,
    required this.onSelect,
    required this.onSignIn,
    required this.onProfile,
  });

  final double width;
  final bool compact;
  final DeskSection selected;
  final HomeFeed feed;
  final ValueChanged<DeskSection> onSelect;
  final VoidCallback onSignIn, onProfile;

  Widget _item(DeskSection s) => _NavItem(
    s,
    selected: s == selected,
    compact: compact,
    onTap: () => onSelect(s),
  );

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: motionMs(context, 220),
    curve: deskEaseInOut,
    width: width,
    color: scheme.surfaceContainerLow,
    padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: compact
                ? Image.asset(
                    'assets/icon/aniview_icon.png',
                    width: 36,
                    height: 36,
                    cacheWidth: 108,
                  )
                : Image.asset(
                    scheme.brightness == Brightness.light
                        ? 'assets/icon/aniview_wordmark_light.png'
                        : 'assets/icon/aniview_wordmark.png',
                    width: 132,
                  ),
          ),
        ),
        for (final s in const [
          DeskSection.home,
          DeskSection.schedule,
          DeskSection.list,
          DeskSection.downloads,
        ])
          _item(s),
        const Spacer(),
        _item(DeskSection.settings),
        const SizedBox(height: 8),
        _Account(
          feed: feed,
          compact: compact,
          onSignIn: onSignIn,
          onProfile: onProfile,
        ),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem(
    this.section, {
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final DeskSection section;
  final bool selected, compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: compact ? section.label : '',
        waitDuration: const Duration(milliseconds: 400),
        child: Hover(
          onTap: onTap,
          builder: (context, hovered) => AnimatedContainer(
            duration: motionMs(context, 120),
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            alignment: compact ? Alignment.center : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: .16)
                  : hovered
                  ? scheme.onSurface.withValues(alpha: .07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(buttonRadius),
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Icon(
                  selected ? section.selected : section.icon,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (!compact) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                        color: selected
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: .85),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account({
    required this.feed,
    required this.compact,
    required this.onSignIn,
    required this.onProfile,
  });

  final HomeFeed feed;
  final bool compact;
  final VoidCallback onSignIn, onProfile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: feed.viewer,
      builder: (context, snap) {
        final me = snap.data;
        final avatar = me?['avatar']?['large'] as String?;
        final name = me?['name'] as String?;
        final face = CircleAvatar(
          radius: 16,
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundImage: avatar == null ? null : NetworkImage(avatar),
          child: Icon(
            Icons.person_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        );
        return Hover(
          onTap: Tracker.signedIn ? onProfile : onSignIn,
          builder: (context, hovered) => AnimatedContainer(
            duration: motionMs(context, 120),
            height: 52,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
            alignment: compact ? Alignment.center : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: hovered
                  ? scheme.onSurface.withValues(alpha: .07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(buttonRadius),
            ),
            child: compact
                ? face
                : Row(
                    children: [
                      face,
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name ?? 'Not signed in',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelLarge,
                            ),
                            Text(
                              Tracker.signedIn
                                  ? Tracker.providers.first.name
                                  : 'Sign in',
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
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.focus,
    required this.canGoBack,
    required this.onBack,
    required this.onSearch,
    required this.onRefresh,
    required this.actions,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool canGoBack;
  final VoidCallback onBack;
  final ValueChanged<String> onSearch;
  final Future<void> Function() onRefresh;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: scheme.surface,
      border: Border(bottom: BorderSide(color: hairline)),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back  (Alt+←)',
          onPressed: canGoBack ? onBack : null,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        // The search box sits in the middle of the bar, as wide as the window lets it be up to a point.
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: DeskSearchBox(
                controller: controller,
                focus: focus,
                onSearch: onSearch,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
        ...actions,
      ],
    ),
  );
}
