import 'dart:async';

import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'settings.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';

Future<void> openSearch(BuildContext context, SearchFilters filters) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(filters: filters)),
    );

const _keep = Object(); // an argument left out of [_SearchScreenState._copy]
const _any = ''; // the "Any" choice in a filter's picker

const _sorts = <String?, String>{
  null: 'Best match',
  'POPULARITY_DESC': 'Popular',
  'TRENDING_DESC': 'Trending',
  'SCORE_DESC': 'Top rated',
  'START_DATE_DESC': 'Newest',
};
const _seasons = <String?, String>{
  null: 'Any',
  'WINTER': 'Winter',
  'SPRING': 'Spring',
  'SUMMER': 'Summer',
  'FALL': 'Fall',
};
const _formats = <String?, String>{
  null: 'Any',
  'TV': 'TV',
  'MOVIE': 'Movie',
  'OVA': 'OVA',
  'ONA': 'ONA',
  'SPECIAL': 'Special',
  'TV_SHORT': 'TV short',
};
const _statuses = <String?, String>{
  null: 'Any',
  'RELEASING': 'Airing',
  'FINISHED': 'Finished',
  'NOT_YET_RELEASED': 'Upcoming',
};
const _genres = [
  'Action',
  'Adventure',
  'Comedy',
  'Drama',
  'Ecchi',
  'Fantasy',
  'Horror',
  'Mahou Shoujo',
  'Mecha',
  'Music',
  'Mystery',
  'Psychological',
  'Romance',
  'Sci-Fi',
  'Slice of Life',
  'Sports',
  'Supernatural',
  'Thriller',
];

/// Search by title, or browse by filters alone. Before anything is typed it offers recent searches and genres.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.filters});

  /// Opens browsing these right away ("See all", a genre chip) instead of an empty search.
  final SearchFilters? filters;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// A search as it's typed: it waits for a pause in typing, skips a single letter, browses by the filters alone
/// when there's no text, drops answers to searches replaced since, and loads further pages as asked (and by
/// itself after a short page, which wouldn't fill the screen enough to scroll for more). Pages come from [fetch].
class SearchSession extends ChangeNotifier {
  SearchSession({
    required this.fetch,
    this.filters = const SearchFilters(),
    this.pause = const Duration(milliseconds: 450),
    this.onSearch,
  });

  /// One page of results for a query and filters, and whether there's another.
  final Future<(List, bool)> Function(
    String query,
    SearchFilters filters,
    int page,
  )
  fetch;

  /// How long typing must stop before a search runs.
  final Duration pause;

  /// Told of each search as it runs (for usage stats).
  final void Function(String query, SearchFilters filters)? onSearch;

  String query = '';
  SearchFilters filters;
  List items = [];
  Object? error;
  bool searched = false, loading = false, hasNext = false;
  int _page = 0, _generation = 0;
  Timer? _debounce;

  /// Text typed so far: searches once typing pauses.
  void type(String text) => _search(text, pause);

  /// Text submitted (or picked, or spoken): searches now.
  void submit(String text) => _search(text, Duration.zero);

  /// New filters, searched now with [text].
  void filter(SearchFilters picked, String text) {
    filters = picked;
    submit(text);
  }

  /// Back to no search: no text, filters or results.
  void clear() {
    _debounce?.cancel();
    _generation++;
    query = '';
    searched = loading = false;
    items = [];
    error = null;
    filters = const SearchFilters();
    notifyListeners();
  }

  /// The next page, unless one is loading or there's none.
  Future<void> more() => _load(fresh: false);

  /// The first page again, after an error.
  Future<void> retry() => _load(fresh: true);

  void _search(String text, Duration wait) {
    _debounce?.cancel();
    final q = text.trim();
    final browsing = filters.count > 0 || filters.sort != null;
    if (q.length == 1) return;
    if (q.isEmpty && !browsing) {
      if (searched) clear();
      return;
    }
    _debounce = Timer(wait, () {
      query = q;
      searched = true;
      onSearch?.call(q, filters);
      _load(fresh: true);
    });
  }

  Future<void> _load({required bool fresh}) async {
    if (!fresh && (loading || !hasNext)) return;
    final generation = fresh ? ++_generation : _generation;
    final next = fresh ? 1 : _page + 1;
    loading = true;
    error = null;
    if (fresh) items = [];
    notifyListeners();
    try {
      final (found, more) = await fetch(query, filters, next);
      if (generation != _generation) return; // a newer search replaced this one
      items = [...items, ...found];
      _page = next;
      hasNext = more;
      loading = false;
      notifyListeners();
      if (more && found.length < 20) _load(fresh: false);
    } catch (e) {
      if (generation != _generation) return;
      error = e;
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++; // answers still on their way are dropped
    super.dispose();
  }
}

class _SearchScreenState extends State<SearchScreen> {
  final controller = TextEditingController();
  late final search = SearchSession(
    fetch: (query, filters, page) => Tracker.search(query, filters, page: page),
    filters: widget.filters ?? const SearchFilters(),
    // Never the text itself.
    onSearch: (query, filters) => Analytics.event('search', {
      'has_text': query.isNotEmpty,
      'filters': filters.count,
    }),
  )..addListener(() => setState(() {}));

  String get query => search.query;
  SearchFilters get filters => search.filters;

  /// What's popular, so an empty search still has somewhere to go.
  late final trending = Tracker.trending();

  @override
  void initState() {
    super.initState();
    Analytics.screen('/search', title: 'Search');
    if (widget.filters != null) search.submit('');
    // The remote's search key (see [voiceSearch]), whether it opened this page or found it open.
    if (widget.filters == null) {
      voiceSearch.addListener(_voiceRequested);
      remoteQuery.addListener(_remoteTyped);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _voiceRequested();
        _remoteTyped();
      });
    }
  }

  /// Typed on the phone remote (see [remoteQuery]): searched as it's typed here.
  void _remoteTyped() {
    final query = remoteQuery.value;
    if (query == null || !mounted) return;
    remoteQuery.value = null;
    controller.text = query;
    search.type(query);
  }

  void _voiceRequested() {
    if (!voiceSearch.value || !mounted) return;
    voiceSearch.value = false;
    _listen();
  }

  @override
  void dispose() {
    voiceSearch.removeListener(_voiceRequested);
    remoteQuery.removeListener(_remoteTyped);
    search.dispose();
    controller.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    try {
      final spoken = await recognizeSpeech();
      if (spoken == null || spoken.isEmpty || !mounted) return;
      controller.text = spoken;
      search.submit(spoken);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Keeps a query that led somewhere (a show was opened from its results).
  void _remember() {
    if (query.isEmpty) return;
    Settings.recentSearches = [
      query,
      ...Settings.recentSearches.where(
        (q) => q.toLowerCase() != query.toLowerCase(),
      ),
    ];
  }

  void _setFilters(SearchFilters picked) {
    Analytics.event('search_filter', {
      'filters': picked.count,
      'sort': picked.sort,
    });
    search.filter(picked, controller.text);
  }

  /// Back to recent searches and genres.
  void _clear() {
    controller.clear();
    search.clear();
  }

  SearchFilters _copy({
    Object? sort = _keep,
    Object? season = _keep,
    Object? year = _keep,
    Object? format = _keep,
    Object? status = _keep,
    Set<String>? genres,
  }) {
    final f = filters;
    return SearchFilters(
      sort: sort == _keep ? f.sort : sort as String?,
      season: season == _keep ? f.season : season as String?,
      year: year == _keep ? f.year : year as int?,
      format: format == _keep ? f.format : format as String?,
      status: status == _keep ? f.status : status as String?,
      genres: genres ?? f.genres,
    );
  }

  /// Filters as a row of chips, each opening a short list of its own choices, instead of one long sheet.
  Widget _filterBar() {
    final f = filters;
    Future<void> one(
      String title,
      Map<String, String> options,
      String current,
      SearchFilters Function(String picked) apply,
    ) async {
      final picked = await pickOne(context, title, options, current);
      if (picked != null && mounted) _setFilters(apply(picked));
    }

    final chips = [
      _chip(
        f.sort == null ? 'Sort' : _sorts[f.sort]!,
        f.sort != null,
        () => one(
          'Sort by',
          _choices(_sorts),
          f.sort ?? _any,
          (v) => _copy(sort: v == _any ? null : v),
        ),
      ),
      _chip(
        switch (f.genres.length) {
          0 => 'Genres',
          1 => f.genres.first,
          final n => '$n genres',
        },
        f.genres.isNotEmpty,
        () async {
          final picked = await pickMany(context, 'Genres', _genres, f.genres);
          if (picked != null && mounted) {
            _setFilters(_copy(genres: picked));
          }
        },
      ),
      _chip(
        f.season == null ? 'Season' : _seasons[f.season]!,
        f.season != null,
        () => one(
          'Season',
          _choices(_seasons),
          f.season ?? _any,
          (v) => _copy(season: v == _any ? null : v),
        ),
      ),
      _chip(
        f.year == null ? 'Year' : '${f.year}',
        f.year != null,
        () => one(
          'Year',
          {
            _any: 'Any',
            for (var y = DateTime.now().year + 1; y >= 1970; y--) '$y': '$y',
          },
          f.year == null ? _any : '${f.year}',
          (v) => _copy(year: v == _any ? null : int.parse(v)),
        ),
      ),
      _chip(
        f.format == null ? 'Format' : _formats[f.format]!,
        f.format != null,
        () => one(
          'Format',
          _choices(_formats),
          f.format ?? _any,
          (v) => _copy(format: v == _any ? null : v),
        ),
      ),
      _chip(
        f.status == null ? 'Status' : _statuses[f.status]!,
        f.status != null,
        () => one(
          'Status',
          _choices(_statuses),
          f.status ?? _any,
          (v) => _copy(status: v == _any ? null : v),
        ),
      ),
    ];
    // Two rows of three, all in view: no scrolling sideways to find one.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: side),
      child: Column(
        children: [
          for (var row = 0; row < 2; row++)
            Padding(
              padding: EdgeInsets.only(top: row == 0 ? 0 : 8),
              child: TvRow(
                child: Row(
                  children: [
                    for (var i = row * 3; i < row * 3 + 3; i++) ...[
                      if (i % 3 > 0) const SizedBox(width: 8),
                      Expanded(child: chips[i]),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// [options] with "Any" (null) under a key the picker can return.
  Map<String, String> _choices(Map<String?, String> options) => {
    for (final MapEntry(:key, :value) in options.entries) key ?? _any: value,
  };

  /// A filter as a dropdown-like chip filling its column: the choice (or the filter's name) and an arrow.
  Widget _chip(String label, bool active, VoidCallback onTap) => FilterChip(
    selected: active,
    showCheckmark: false,
    label: Row(
      children: [
        Expanded(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        // The label's colour, which inverts with it when focused on TV.
        Builder(
          builder: (context) => Icon(
            Icons.arrow_drop_down_rounded,
            size: 18,
            color: DefaultTextStyle.of(context).style.color,
          ),
        ),
      ],
    ),
    onSelected: (_) => onTap(),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                Navigator.canPop(context) ? 4 : side,
                isTv ? 24 : 8,
                side - 4,
                8,
              ),
              child: Row(
                children: [
                  if (Navigator.canPop(context)) const BackButton(),
                  Expanded(child: _field()),
                  if (filters.count > 0 || filters.sort != null)
                    TextButton(
                      onPressed: () => _setFilters(const SearchFilters()),
                      child: const Text('Clear filters'),
                    ),
                ],
              ),
            ),
            _filterBar(),
            const SizedBox(height: 8),
            Expanded(child: _results()),
          ],
        ),
      ),
    );
  }

  /// A rounded search field (the M3 search bar). On TV the mic leads: focusing the field opens the on-screen
  /// keyboard over everything, and speaking is quicker than typing with a remote.
  Widget _field() => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => TextField(
      controller: controller,
      autofocus: widget.filters == null && !isTv,
      textInputAction: TextInputAction.search,
      onChanged: search.type,
      onSubmitted: search.submit,
      decoration: InputDecoration(
        hintText: 'Search anime',
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        prefixIcon: isTv
            ? IconButton(
                tooltip: 'Search by voice',
                autofocus: widget.filters == null,
                onPressed: _listen,
                icon: const Icon(Icons.mic_rounded),
              )
            : const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty && !search.searched
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: _clear,
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    ),
  );

  Widget _results() {
    final text = Theme.of(context).textTheme;
    if (!search.searched) {
      final recent = Settings.recentSearches;
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (recent.isNotEmpty) ...[
            SectionHeader(
              'Recent searches',
              action: TextButton(
                onPressed: () =>
                    setState(() => Settings.recentSearches = const []),
                child: const Text('Clear'),
              ),
            ),
            for (final q in recent)
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: Text(q),
                onTap: () {
                  controller.text = q;
                  search.submit(q);
                },
              ),
          ],
          FutureBuilder(
            future: trending,
            builder: (context, snap) => (snap.data ?? const []).isEmpty
                ? const SizedBox.shrink()
                : MediaRow('Trending now', snap.data!),
          ),
          const SectionHeader('Browse by genre'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final genre in _genres)
                  ActionChip(
                    label: Text(genre),
                    onPressed: () =>
                        _setFilters(SearchFilters(genres: {genre})),
                  ),
              ],
            ),
          ),
          if (recent.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 0),
              child: Text(
                'Search by English or Japanese title, or narrow things down with filters.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      );
    }
    if (search.items.isEmpty && search.loading) {
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(side, 8, side, 24),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: posterGrid,
        itemCount: 12,
        itemBuilder: (_, _) => const Align(
          alignment: Alignment.topCenter,
          child: AspectRatio(aspectRatio: 2 / 3, child: Skeleton()),
        ),
      );
    }
    if (search.items.isEmpty && search.error != null) {
      return ErrorState(search.error!, onRetry: search.retry);
    }
    if (search.items.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: query.isEmpty
            ? 'No shows match these filters'
            : 'No results for “$query”',
        message: filters.count > 0
            ? 'Try removing a filter'
            : 'Check the spelling or try the other title',
        action: filters.count == 0
            ? null
            : FilledButton.tonal(
                autofocus: isTv,
                onPressed: () => _setFilters(const SearchFilters()),
                child: const Text('Clear filters'),
              ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 800 && search.error == null) search.more();
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 8, side, 0),
            sliver: SliverGrid.builder(
              gridDelegate: posterGrid,
              itemCount: search.items.length,
              itemBuilder: (context, i) =>
                  PosterCard(search.items[i], onBack: _remember),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              child: search.error != null
                  ? ErrorState(
                      search.error!,
                      compact: true,
                      onRetry: search.more,
                    )
                  : search.loading
                  ? const Center(child: CircularProgressIndicator())
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
