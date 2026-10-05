import 'package:flutter/material.dart';

import '../anilist.dart';
import '../desktop.dart' show openMenu;
import '../search.dart';
import '../settings.dart';
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';
import 'shell.dart' show DeskSearchRequest;
import 'widgets.dart';

/// Desktop Search, in the way of Plex and Jellyfin's libraries: the results as a grid of posters under a toolbar of
/// drop-downs (genre, year, season, format, status, sort), the ones in use lit and listed as chips you can take
/// off. The grid keeps loading as you scroll. With nothing typed there are recent searches, genre tiles and what's
/// trending or on this season.
class DeskSearch extends StatefulWidget {
  const DeskSearch(this.request, {super.key, required this.onReload});

  final ValueNotifier<DeskSearchRequest> request;
  final void Function({bool force}) onReload;

  @override
  State<DeskSearch> createState() => _DeskSearchState();
}

class _DeskSearchState extends State<DeskSearch> {
  late final session = SearchSession(
    fetch: (query, filters, page) => Tracker.search(query, filters, page: page),
  )..addListener(() => setState(() {}));
  final _scroll = ScrollController();
  late final trending = Tracker.trending();
  late final season = Tracker.season();
  String text = '';

  @override
  void initState() {
    super.initState();
    widget.request.addListener(_requested);
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.extentAfter < 900 &&
          session.hasNext) {
        session.more();
      }
    });
    _requested();
  }

  @override
  void dispose() {
    widget.request.removeListener(_requested);
    session.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _requested() {
    final request = widget.request.value;
    text = request.text;
    session.filters = request.filters;
    if (text.length > 1) _remember(text);
    session.submit(text);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Keeps a query that was run, newest first.
  void _remember(String query) => Settings.recentSearches = [
    query,
    ...Settings.recentSearches.where(
      (q) => q.toLowerCase() != query.toLowerCase(),
    ),
  ].take(12).toList();

  void _filter(SearchFilters filters) =>
      widget.request.value = DeskSearchRequest(text, filters);

  @override
  Widget build(BuildContext context) =>
      session.searched ? _results() : _start();

  // ───────────────────────────── Results ─────────────────────────────

  Widget _results() {
    final text = Theme.of(context).textTheme;
    final f = session.filters;
    final shown = session.items.length;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(deskMargin, 28, deskMargin, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    session.query.isEmpty
                        ? 'Browse'
                        : 'Results for “${session.query}”',
                    style: text.headlineMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (shown > 0)
                  Text(
                    '$shown${session.hasNext ? '+' : ''} shows',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: _toolbar(f)),
        if (f.count > 0) SliverToBoxAdapter(child: _active(f)),
        if (session.error != null && shown == 0)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorState(session.error!, onRetry: session.retry),
          )
        else if (session.loading && shown == 0)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (shown == 0)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Nothing found',
              message: 'Try fewer filters or another spelling.',
            ),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(deskMargin, 12, deskMargin, 24),
            sliver: SliverGrid.builder(
              gridDelegate: const DeskPosterGrid(),
              itemCount: shown,
              itemBuilder: (context, i) {
                final poster = DeskPoster(
                  session.items[i],
                  onChanged: () => widget.onReload(force: true),
                );
                // A new search arrives poster by poster; ones loaded further down just appear.
                return i < 18 ? Reveal(index: i, child: poster) : poster;
              },
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 56,
              child: session.loading
                  ? const Center(child: CircularProgressIndicator())
                  : null,
            ),
          ),
        ],
      ],
    );
  }

  // ───────────────────────────── The toolbar ─────────────────────────────

  Widget _toolbar(SearchFilters f) {
    // A one-choice drop-down: [options] by value, [current] ticked, [apply] making the new filters.
    Widget one(
      String label,
      Map<String?, String> options,
      String? current,
      SearchFilters Function(String? picked) apply, {
      bool anyFirst = true,
    }) => _Dropdown(
      label: current == null ? label : '$label · ${options[current]}',
      active: current != null,
      children: [
        for (final MapEntry(:key, :value) in options.entries)
          MenuItemButton(
            leadingIcon: Icon(
              key == current ? Icons.check_rounded : null,
              size: 20,
            ),
            onPressed: () => _filter(apply(key)),
            child: Text(value),
          ),
      ],
    );
    final years = [for (var y = DateTime.now().year + 1; y >= 1990; y--) y];
    return Padding(
      padding: const EdgeInsets.fromLTRB(deskMargin, 12, deskMargin, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Dropdown(
            label: switch (f.genres.length) {
              0 => 'Genre',
              1 => 'Genre · ${f.genres.first}',
              final n => 'Genre · $n',
            },
            active: f.genres.isNotEmpty,
            children: [
              for (final genre in searchGenres)
                CheckboxMenuButton(
                  closeOnActivate: false,
                  value: f.genres.contains(genre),
                  onChanged: (on) => _filter(
                    f.copyWith(
                      genres: on == true
                          ? {...f.genres, genre}
                          : {
                              for (final g in f.genres)
                                if (g != genre) g,
                            },
                    ),
                  ),
                  child: Text(genre),
                ),
            ],
          ),
          _Dropdown(
            label: f.year == null ? 'Year' : 'Year · ${f.year}',
            active: f.year != null,
            children: [
              MenuItemButton(
                leadingIcon: Icon(f.year == null ? Icons.check_rounded : null),
                onPressed: () => _filter(f.copyWith(year: () => null)),
                child: const Text('Any'),
              ),
              for (final y in years)
                MenuItemButton(
                  leadingIcon: Icon(y == f.year ? Icons.check_rounded : null),
                  onPressed: () => _filter(f.copyWith(year: () => y)),
                  child: Text('$y'),
                ),
            ],
          ),
          one(
            'Season',
            searchSeasons,
            f.season,
            (v) => f.copyWith(season: () => v),
          ),
          one(
            'Format',
            searchFormats,
            f.format,
            (v) => f.copyWith(format: () => v),
          ),
          one(
            'Status',
            searchStatuses,
            f.status,
            (v) => f.copyWith(status: () => v),
          ),
          if (Tracker.signedIn)
            FilterChip(
              showCheckmark: false,
              avatar: Icon(
                f.unwatched
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
              label: const Text('Hide what I\'ve watched'),
              selected: f.unwatched,
              onSelected: (v) => _filter(f.copyWith(unwatched: v)),
            ),
          const SizedBox(width: 8),
          _Dropdown(
            icon: Icons.sort_rounded,
            label: 'Sort · ${searchSorts[f.sort]}',
            active: f.sort != null,
            children: [
              for (final MapEntry(:key, :value) in searchSorts.entries)
                MenuItemButton(
                  leadingIcon: Icon(key == f.sort ? Icons.check_rounded : null),
                  onPressed: () => _filter(f.copyWith(sort: () => key)),
                  child: Text(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// What's narrowing the results, each as a chip to take off.
  Widget _active(SearchFilters f) {
    String? name(Map<String?, String> options, String? key) =>
        key == null ? null : options[key];
    final chips = <(String, SearchFilters)>[
      for (final g in f.genres)
        (
          g,
          f.copyWith(
            genres: {
              for (final x in f.genres)
                if (x != g) x,
            },
          ),
        ),
      if (f.year != null) ('${f.year}', f.copyWith(year: () => null)),
      if (name(searchSeasons, f.season) case final s?)
        (s, f.copyWith(season: () => null)),
      if (name(searchFormats, f.format) case final s?)
        (s, f.copyWith(format: () => null)),
      if (name(searchStatuses, f.status) case final s?)
        (s, f.copyWith(status: () => null)),
      if (f.unwatched) ('Hiding watched', f.copyWith(unwatched: false)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(deskMargin, 12, deskMargin, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (label, without) in chips)
            InputChip(label: Text(label), onDeleted: () => _filter(without)),
          TextButton(
            onPressed: () =>
                _filter(SearchFilters(sort: f.sort)), // the sort stays
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── Nothing typed yet ─────────────────────────────

  /// A hue for each genre's tile, so the grid isn't a wall of one colour.
  static Color _tint(int i) =>
      HSLColor.fromAHSL(1, (i * 47.0) % 360, .55, .32).toColor();

  Widget _start() {
    final text = Theme.of(context).textTheme;
    final recent = Settings.recentSearches;
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        const DeskHeader('Search', note: 'Find a show, or browse by genre'),
        if (recent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(deskMargin, 20, deskMargin, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Recent searches', style: text.titleLarge),
                    const Spacer(),
                    TextButton(
                      onPressed: () =>
                          setState(() => Settings.recentSearches = const []),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final q in recent)
                      InputChip(
                        label: Text(q),
                        avatar: const Icon(Icons.history_rounded, size: 18),
                        onPressed: () => widget.request.value =
                            DeskSearchRequest(q, session.filters),
                        onDeleted: () => setState(
                          () => Settings.recentSearches = [
                            for (final r in recent)
                              if (r != q) r,
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(deskMargin, 28, deskMargin, 12),
          child: Text('Browse by genre', style: text.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: deskMargin),
          child: Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final (i, genre) in searchGenres.indexed)
                SizedBox(
                  width: 200,
                  child: Hover(
                    onTap: () => widget.request.value = DeskSearchRequest(
                      '',
                      SearchFilters(genres: {genre}),
                    ),
                    builder: (context, hovered) => AnimatedContainer(
                      duration: motionMs(context, 140),
                      height: 84,
                      alignment: Alignment.bottomLeft,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            _tint(i),
                            Color.lerp(_tint(i), Colors.black, .35)!,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(radiusLarge),
                        border: Border.all(
                          color: hovered
                              ? Colors.white.withValues(alpha: .7)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        genre,
                        style: text.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _row('Trending now', trending),
        _row('Popular this season', season),
      ],
    );
  }

  Widget _row(String title, Future<List> future) => FutureBuilder(
    future: future,
    builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
        ? DeskRow(
            title,
            snap.data!,
            onChanged: () => widget.onReload(force: true),
          )
        : const SizedBox.shrink(),
  );
}

/// A toolbar pill that opens its [children] as a menu under it, lit while one of its choices is in use.
class _Dropdown extends StatefulWidget {
  const _Dropdown({
    required this.label,
    required this.active,
    required this.children,
    this.icon,
  });

  final String label;
  final bool active;
  final List<Widget> children;
  final IconData? icon;

  @override
  State<_Dropdown> createState() => _DropdownState();
}

class _DropdownState extends State<_Dropdown> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _menu,
    // Esc closes it, rather than going back a page (see [DesktopKeys]).
    onOpen: () => openMenu = _menu,
    onClose: () {
      if (openMenu == _menu) openMenu = null;
    },
    menuChildren: widget.children,
    style: MenuStyle(
      maximumSize: const WidgetStatePropertyAll(Size(320, 420)),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
    ),
    builder: (context, controller, _) => Hover(
      onTap: () => controller.isOpen ? controller.close() : controller.open(),
      builder: (context, hovered) => AnimatedContainer(
        duration: motionMs(context, 120),
        height: 36,
        padding: const EdgeInsets.only(left: 14, right: 8),
        decoration: BoxDecoration(
          color: widget.active
              ? scheme.primary.withValues(alpha: .16)
              : hovered || controller.isOpen
              ? scheme.onSurface.withValues(alpha: .08)
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(buttonRadius),
          border: Border.all(
            color: widget.active
                ? scheme.primary.withValues(alpha: .6)
                : hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(
                widget.icon,
                size: 18,
                color: widget.active ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              widget.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: widget.active ? scheme.primary : scheme.onSurface,
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: widget.active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ),
  );
}
