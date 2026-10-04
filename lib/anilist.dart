import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop/sign_in.dart';
import 'pairing.dart';
import 'platform.dart';
import 'tv.dart';

String titleOf(Map media) =>
    media['title']['userPreferred'] ??
    media['title']['romaji'] ??
    media['title']['english'] ??
    '';

/// A show as AniList describes it (MyAnimeList's answers are mapped to the same shape), read through the facts
/// screens need instead of the JSON. A view over the map, not a copy: [Tracker] still updates the map itself.
extension type const Show(Map raw) {
  Object? get id => raw['id'];

  /// The AniList id, or null while it's unknown (a show from MyAnimeList carries `mal:<id>` until ani.zip answers).
  int? get anilistId => raw['id'] is int ? raw['id'] : null;
  bool get onAniList => anilistId != null;

  /// Whether [other] is the same show, by AniList id or, when one side lacks it, MyAnimeList id.
  bool sameAs(Map other) =>
      raw['id'] == other['id'] ||
      (raw['idMal'] != null && raw['idMal'] == other['idMal']);
  String get title => titleOf(raw);
  String? get cover => raw['coverImage']?['extraLarge'];

  /// The cover's dominant colour, "#rrggbb".
  String? get color => raw['coverImage']?['color'];

  /// The wide banner, else the cover, for backdrops.
  String? get backdrop => raw['bannerImage'] ?? cover;
  bool get hasBanner => raw['bannerImage'] != null;
  int? get score => raw['averageScore'];
  String? get description => raw['description'];
  List get genres => raw['genres'] as List? ?? const [];

  /// The full episode count, when known; what list tracking completes at.
  int? get episodes => raw['episodes'];

  /// Episodes out so far: the full count, else those before the one airing next.
  int? get aired {
    final next = raw['nextAiringEpisode']?['episode'] as int?;
    return episodes ?? (next == null ? null : next - 1);
  }

  /// Whether it's on the user's AniList list, and their entry's status and episodes watched there.
  bool get inList => raw['mediaListEntry'] != null;
  String? get listStatus => raw['mediaListEntry']?['status'];
  int get progress => raw['mediaListEntry']?['progress'] as int? ?? 0;
}

/// Search filters as AniList enum values (season "FALL", format "TV", …); null means any.
class SearchFilters {
  const SearchFilters({
    this.sort,
    this.season,
    this.year,
    this.format,
    this.status,
    this.genres = const {},
    this.unwatched = false,
  });

  final String? sort, season, format, status;
  final int? year;
  final Set<String> genres; // all of them, like AniList's genre_in

  /// Leaves out shows you're watching or have completed (signed in only).
  final bool unwatched;

  /// These with some changed. A filter that can be unset is given as a function, so `sort: () => null` clears
  /// it and leaving it out keeps it.
  SearchFilters copyWith({
    String? Function()? sort,
    String? Function()? season,
    int? Function()? year,
    String? Function()? format,
    String? Function()? status,
    Set<String>? genres,
    bool? unwatched,
  }) => SearchFilters(
    sort: sort == null ? this.sort : sort(),
    season: season == null ? this.season : season(),
    year: year == null ? this.year : year(),
    format: format == null ? this.format : format(),
    status: status == null ? this.status : status(),
    genres: genres ?? this.genres,
    unwatched: unwatched ?? this.unwatched,
  );

  /// How many filters narrow the results; sorting doesn't count.
  int get count =>
      [season, year, format, status].whereType<Object>().length +
      genres.length +
      (unwatched ? 1 : 0);

  /// For results that couldn't be filtered server-side (MyAnimeList).
  bool matches(Map media) =>
      (season == null || media['season'] == season) &&
      (year == null || media['seasonYear'] == year) &&
      (format == null || media['format'] == format) &&
      (status == null || media['status'] == status) &&
      genres.every((media['genres'] as List).contains) &&
      (!unwatched ||
          !const {
            'CURRENT',
            'REPEATING',
            'COMPLETED',
          }.contains(media['mediaListEntry']?['status']));
}

/// AniList SSO (implicit grant) and the GraphQL calls the app needs.
class AniList {
  static const clientId = String.fromEnvironment('ANILIST_CLIENT_ID');
  static const _media =
      'id idMal title{userPreferred romaji english} coverImage{extraLarge color} bannerImage '
      'episodes description averageScore genres format status season seasonYear '
      'nextAiringEpisode{episode airingAt} mediaListEntry{progress status}';

  static String? token;
  static Map<String, dynamic>? _viewer;

  static bool get usable => clientId.isNotEmpty;

  static Future<void> load() async {
    token = (await SharedPreferences.getInstance()).getString('anilist_token');
  }

  /// Shows AniList's authorize page in-app and captures the token from the `aniview://auth#access_token=…` redirect.
  /// A TV first offers pairing a phone, which signs it in too, since typing a password with a remote is painful.
  static Future<void> login(BuildContext context) async {
    if (isTv &&
        await Navigator.of(context).push<String>(
              MaterialPageRoute(builder: (_) => const TvPairScreen()),
            ) !=
            TvPairScreen.signInHere) {
      return; // signed in by the phone, or closed
    }
    if (!context.mounted) return;
    // The desktop uses the system browser, where the person is likely signed in to AniList already.
    if (isDesktop) {
      final value = await signInInBrowser(
        context,
        'https://anilist.co/api/v2/oauth/authorize?client_id=$clientId&response_type=token',
      );
      if (value != null && value.isNotEmpty) await useToken(value);
      return;
    }
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _LoginPage(),
      ),
    );
    if (value != null && value.isNotEmpty) await useToken(value);
  }

  static Future<void> useToken(String value) async {
    token = value;
    _viewer = null;
    await (await SharedPreferences.getInstance()).setString(
      'anilist_token',
      value,
    );
  }

  static Future<void> logout() async {
    token = null;
    _viewer = null;
    await (await SharedPreferences.getInstance()).remove('anilist_token');
  }

  /// Answers every query instead of the network; set by tests.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String query,
    Map<String, dynamic> variables,
  )?
  transport;

  static Future<Map<String, dynamic>> query(
    String query, [
    Map<String, dynamic> variables = const {},
  ]) async {
    if (transport != null) return transport!(query, variables);
    final res = await http.post(
      Uri.parse('https://graphql.anilist.co'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'query': query, 'variables': variables}),
    );
    if (res.statusCode == 429) {
      final wait = int.tryParse(res.headers['retry-after'] ?? '') ?? 60;
      throw Exception(
        'AniList is getting too many requests. Try again in ${wait}s',
      );
    }
    // A whole list is hundreds of KB: decoded on the UI thread it drops frames (a back animation, a scroll).
    final text = res.body;
    final body =
        (text.length > 32 * 1024
                ? await Isolate.run(() => jsonDecode(text))
                : jsonDecode(text))
            as Map<String, dynamic>;
    final errors = body['errors'] as List?;
    if (errors != null && errors.isNotEmpty) {
      final message = errors.first['message'] as String;
      if (res.statusCode == 401 || message.contains('Invalid token')) {
        await logout();
      }
      throw Exception(message);
    }
    return body['data'] as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> viewer() async {
    if (token == null) return null;
    return _viewer ??= (await query(
      'query{Viewer{id name avatar{large}}}',
    ))['Viewer'];
  }

  /// Your anime totals ({count, episodesWatched, minutesWatched, statuses: [{status, count}]}) and the days
  /// you updated your list ({date, amount}); null signed out.
  static Future<Map<String, dynamic>?> stats() async {
    if (token == null) return null;
    final viewer = (await query(
      'query{Viewer{id statistics{anime{count episodesWatched minutesWatched statuses{status count}}} '
      'stats{activityHistory{date amount}}}}',
    ))['Viewer'];
    final anime = viewer['statistics']?['anime'];
    // AniList leaves the breakdown empty for some accounts that do have a list; count it from the list itself.
    if (anime != null && (anime['statuses'] as List? ?? const []).isEmpty) {
      final lists = (await query(
        r'query($u:Int){MediaListCollection(userId:$u,type:ANIME){lists{status isCustomList entries{id}}}}',
        {'u': viewer['id']},
      ))['MediaListCollection']['lists'];
      anime['statuses'] = [
        for (final l in lists)
          if (l['isCustomList'] != true && l['status'] != null)
            {'status': l['status'], 'count': (l['entries'] as List).length},
      ];
    }
    return viewer;
  }

  static Future<List> trending() async => (await query(
    'query{Page(perPage:20){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){$_media}}}',
  ))['Page']['media'];

  /// AniList season name and year for today (WINTER = Jan–Mar, SPRING, SUMMER, FALL).
  static (String, int) get currentSeason {
    final now = DateTime.now();
    return (
      const ['WINTER', 'SPRING', 'SUMMER', 'FALL'][(now.month - 1) ~/ 3],
      now.year,
    );
  }

  /// Most popular shows of the current season.
  static Future<List> season() async {
    final (season, year) = currentSeason;
    return (await query(
      r'query($s:MediaSeason,$y:Int){Page(perPage:20){media(type:ANIME,season:$s,seasonYear:$y,'
      r'sort:POPULARITY_DESC,isAdult:false){'
      '$_media}}}',
      {'s': season, 'y': year},
    ))['Page']['media'];
  }

  /// One [page] of results and whether there's another. [text] may be empty to browse by [filters] alone.
  static Future<(List, bool)> search(
    String text, [
    SearchFilters filters = const SearchFilters(),
    int page = 1,
  ]) async {
    // Fetched once per search, for its later pages too.
    if (filters.unwatched && (page == 1 || _watched == null)) {
      _watched = watchedIds();
    }
    final watched = filters.unwatched ? await _watched! : const <int>[];
    final data = (await query(
      r'query($page:Int,$s:String,$sort:[MediaSort],$season:MediaSeason,$year:Int,$format:MediaFormat,$status:MediaStatus,$genres:[String],$not:[Int]){'
      r'Page(page:$page,perPage:40){pageInfo{hasNextPage} media(search:$s,type:ANIME,isAdult:false,sort:$sort,season:$season,'
      r'seasonYear:$year,format:$format,status:$status,genre_in:$genres,id_not_in:$not){'
      '$_media}}}',
      // AniList reads an explicit null as "must be null", so unset filters are left out.
      {
        'page': page,
        's': text.isEmpty ? null : text,
        'sort':
            filters.sort ?? (text.isEmpty ? 'POPULARITY_DESC' : 'SEARCH_MATCH'),
        'season': filters.season,
        'year': filters.year,
        'format': filters.format,
        'status': filters.status,
        'genres': filters.genres.isEmpty ? null : filters.genres.toList(),
        'not': watched.isEmpty ? null : watched,
      }..removeWhere((_, v) => v == null),
    ))['Page'];
    return (data['media'] as List, data['pageInfo']['hasNextPage'] == true);
  }

  static Future<List<int>>? _watched;

  // ───────────────────────────── Social ─────────────────────────────

  /// The show's forum threads, most recently replied to first.
  static Future<List> threads(int mediaId) async => (await query(
    r'query($id:Int){Page(perPage:50){threads(mediaCategoryId:$id,sort:[REPLIED_AT_DESC]){'
    r'id title replyCount repliedAt categories{id}}}}',
    {'id': mediaId},
  ))['Page']['threads'];

  static final _releaseThreads = <int, Future<List>>{};

  /// The show's episode discussions (AniList's Release Discussion category), newest first; kept for the session.
  // ponytail: the newest 150, so a long runner's oldest episodes find none; page further if that matters
  static Future<List> releaseThreads(int mediaId) =>
      _releaseThreads[mediaId] ??=
          () async {
            final all = [];
            for (var page = 1; page <= 3; page++) {
              final data = (await query(
                r'query($id:Int,$page:Int){Page(page:$page,perPage:50){pageInfo{hasNextPage} '
                r'threads(mediaCategoryId:$id,categoryId:5,sort:[CREATED_AT_DESC]){id title replyCount repliedAt}}}',
                {'id': mediaId, 'page': page},
              ))['Page'];
              all.addAll(data['threads']);
              if (data['pageInfo']['hasNextPage'] != true) break;
            }
            return all;
          }().catchError((Object e) {
            _releaseThreads.remove(mediaId); // try again next time
            throw e;
          });

  static const _comment =
      'id comment likeCount isLiked createdAt user{name avatar{medium}} childComments';

  /// One page of a thread's comments, oldest first, each with its replies nested under `childComments`.
  static Future<(List, bool)> threadComments(int threadId, int page) async {
    final data = (await query(
      r'query($id:Int,$page:Int){Page(page:$page,perPage:25){pageInfo{hasNextPage} '
      r'threadComments(threadId:$id){'
      '$_comment}}}',
      {'id': threadId, 'page': page},
    ))['Page'];
    return (
      data['threadComments'] as List,
      data['pageInfo']['hasNextPage'] == true,
    );
  }

  /// Posts [text] to a thread, as a reply to [parent] when given; returns the new comment.
  static Future<Map> postComment(
    int threadId,
    String text, {
    int? parent,
  }) async => (await query(
    r'mutation($thread:Int,$parent:Int,$text:String){'
    r'SaveThreadComment(threadId:$thread,parentCommentId:$parent,comment:$text){'
    '$_comment}}',
    // An explicit null parent is rejected; a top-level comment leaves it out.
    {'thread': threadId, 'text': text, 'parent': ?parent},
  ))['SaveThreadComment'];

  /// Likes or unlikes a comment; returns its new {likeCount, isLiked}.
  static Future<Map> toggleCommentLike(int id) async => (await query(
    r'mutation($id:Int){ToggleLikeV2(id:$id,type:THREAD_COMMENT){... on ThreadComment{likeCount isLiked}}}',
    {'id': id},
  ))['ToggleLikeV2'];

  /// Where the people you follow are with a show: their list entries, most recently updated first.
  static Future<List> following(int mediaId) async => (await query(
    r'query($id:Int){Page(perPage:50){mediaList(mediaId:$id,isFollowing:true,sort:UPDATED_TIME_DESC){'
    r'status progress score(format:POINT_100) updatedAt user{name avatar{medium}}}}}',
    {'id': mediaId},
  ))['Page']['mediaList'];

  /// Ids of the shows you're watching, rewatching or have completed; none signed out.
  static Future<List<int>> watchedIds() async {
    final me = await viewer();
    if (me == null) return const [];
    final data = await query(
      r'query($u:Int){MediaListCollection(userId:$u,type:ANIME,status_in:[CURRENT,REPEATING,COMPLETED]){'
      r'lists{entries{mediaId}}}}',
      {'u': me['id']},
    );
    return [
      for (final list in data['MediaListCollection']['lists'])
        for (final entry in list['entries']) entry['mediaId'] as int,
    ];
  }

  static Future<Map> media(int id) async => (await query(
    r'query($id:Int){Media(id:$id){'
    '$_media}}',
    {'id': id},
  ))['Media'];

  /// Anime prequels and sequels of a show as (PREQUEL|SEQUEL, media), prequels first.
  static Future<List<(String, Map)>> relations(int id) async {
    final data = await query(
      r'query($id:Int){Media(id:$id){relations{edges{relationType(version:2) node{type '
      '$_media}}}}}',
      {'id': id},
    );
    return [
      for (final e in data['Media']['relations']['edges'])
        if (e['node']['type'] == 'ANIME' &&
            (e['relationType'] == 'PREQUEL' || e['relationType'] == 'SEQUEL'))
          (e['relationType'] as String, e['node'] as Map),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// Watching (incl. rewatching) and planning entries, most recently updated first; with [all], completed,
  /// paused and dropped ones too.
  static Future<Map<String, List>> lists({bool all = false}) async {
    final me = await viewer();
    if (me == null) return {};
    final data = await query(
      r'query($u:Int,$s:[MediaListStatus]){MediaListCollection(userId:$u,type:ANIME,status_in:$s,'
      r'sort:UPDATED_TIME_DESC){lists{status entries{media{'
      '$_media}}}}}',
      {
        'u': me['id'],
        's': [
          'CURRENT',
          'REPEATING',
          'PLANNING',
          if (all) ...['COMPLETED', 'PAUSED', 'DROPPED'],
        ],
      },
    );
    final out = <String, List>{
      'CURRENT': [],
      'PLANNING': [],
      if (all) ...{'COMPLETED': [], 'PAUSED': [], 'DROPPED': []},
    };
    for (final list in data['MediaListCollection']['lists']) {
      final status = list['status'] as String?;
      // Custom lists come back without a status.
      out[status == 'REPEATING' ? 'CURRENT' : status]?.addAll([
        for (final entry in list['entries']) entry['media'],
      ]);
    }
    return out;
  }

  /// Episodes of the shows in [ids] from a week ago through the week ahead (from the start of today), soonest
  /// first, as {episode, airingAt, media}: one request for both [latestAired] and the schedule.
  static Future<List<Map>> airingAround(Iterable<int> ids) async {
    if (ids.isEmpty) return const [];
    final now = DateTime.now();
    final today =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    final data = await query(
      r'query($ids:[Int],$from:Int,$to:Int){Page(perPage:50){airingSchedules(mediaId_in:$ids,'
      r'airingAt_greater:$from,airingAt_lesser:$to,sort:TIME){episode airingAt media{'
      '$_media}}}}',
      {
        'ids': ids.toSet().toList(),
        'from': now.millisecondsSinceEpoch ~/ 1000 - 7 * 24 * 3600,
        'to': today + 7 * 24 * 3600,
      },
    );
    return [...data['Page']['airingSchedules'] as List].cast<Map>();
  }

  /// This week's episodes (from the start of today) of the most popular shows airing now, soonest first, as
  /// {episode, airingAt, media}: the schedule for someone with no list to go by. [pages] of 50 shows each, one
  /// request apiece (a page of every episode would take a dozen).
  static Future<List<Map>> airingPopular({int pages = 2}) async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final to = from.add(const Duration(days: 7));
    final out = <Map>[];
    for (var page = 1; page <= pages; page++) {
      final data = (await query(
        r'query($p:Int){Page(page:$p,perPage:50){pageInfo{hasNextPage} media(type:ANIME,status:RELEASING,'
        r'isAdult:false,sort:POPULARITY_DESC){airingSchedule(notYetAired:true,perPage:8){nodes{episode airingAt}} '
        '$_media}}}',
        {'p': page},
      ))['Page'];
      for (final media in data['media'] as List) {
        for (final s in media['airingSchedule']['nodes'] as List) {
          final at = DateTime.fromMillisecondsSinceEpoch(
            (s['airingAt'] as int) * 1000,
          );
          if (at.isBefore(to)) {
            out.add({
              'episode': s['episode'],
              'airingAt': s['airingAt'],
              'media': media,
            });
          }
        }
      }
      if (data['pageInfo']['hasNextPage'] != true) break;
    }
    return out
      ..sort((a, b) => (a['airingAt'] as int).compareTo(b['airingAt'] as int));
  }

  /// From [airingAround]: the latest episode that has aired of each show in [ids], newest first.
  static List<Map> latestAired(List<Map> airing, Set<int> ids) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seen = <Object>{};
    return [
      for (final s in airing.reversed)
        if ((s['airingAt'] as int) <= now &&
            ids.contains(s['media']['id']) &&
            seen.add(s['media']['id']))
          s,
    ];
  }

  static Future<int> progressOf(int mediaId) async =>
      (await query(r'query($id:Int){Media(id:$id){mediaListEntry{progress}}}', {
        'id': mediaId,
      }))['Media']['mediaListEntry']?['progress'] ??
      0;

  /// Sets a show's list status and progress (adds it to the list if needed); returns the saved entry.
  static Future<Map<String, dynamic>> saveEntry(
    int mediaId, {
    required String status,
    required int progress,
  }) async => (await query(
    r'mutation($m:Int,$s:MediaListStatus,$p:Int){SaveMediaListEntry(mediaId:$m,status:$s,progress:$p){id status progress}}',
    {'m': mediaId, 's': status, 'p': progress},
  ))['SaveMediaListEntry'];

  static Future<void> removeFromList(int mediaId) async {
    final entry = (await query(
      r'query($m:Int){Media(id:$m){mediaListEntry{id}}}',
      {'m': mediaId},
    ))['Media']['mediaListEntry'];
    if (entry == null) return;
    await query(r'mutation($id:Int){DeleteMediaListEntry(id:$id){deleted}}', {
      'id': entry['id'],
    });
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage();

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  bool _done = false;

  NavigationActionPolicy _intercept(WebUri? url) {
    if (url == null || url.scheme != 'aniview') {
      return NavigationActionPolicy.ALLOW;
    }
    if (!_done) {
      _done = true;
      Navigator.pop(
        context,
        Uri.splitQueryString(url.fragment)['access_token'],
      );
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sign in with AniList')),
    body: InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          'https://anilist.co/api/v2/oauth/authorize?client_id=${AniList.clientId}&response_type=token',
        ),
      ),
      initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, action) async =>
          _intercept(action.request.url),
    ),
  );
}
