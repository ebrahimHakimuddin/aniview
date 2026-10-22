import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'main.dart' show appGeneration, themeGeneration;

import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'anilist.dart' show SearchFilters;
import 'changelog.dart';
import 'downloads.dart';
import 'desktop.dart'
    show keysLabel, rebindSearch, recordShortcut, searchShortcut;
import 'desktop/launcher.dart';
import 'extensions.dart';
import 'history.dart';
import 'jellyfin.dart';
import 'jellyseerr.dart';
import 'notifications.dart';
import 'sources.dart';
import 'pairing.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';
import 'platform.dart';

enum SkipMode { button, auto, off }

/// A fixed set of visual themes; the saved enum names preserve earlier choices.
enum ThemeSelection {
  custom(
    'AniView Custom',
    'Original dark look',
    Color(0xFF01C4FA),
    Brightness.dark,
  ),
  // Seeded from the phone's wallpaper accent (see [systemAccent]); the cyan only stands in if it goes missing.
  dynamicLight(
    'Your colors · Light',
    'Material You · from your wallpaper',
    Color(0xFF01C4FA),
    Brightness.light,
  ),
  dynamicDark(
    'Your colors · Dark',
    'Material You · from your wallpaper',
    Color(0xFF01C4FA),
    Brightness.dark,
  ),
  materialLight(
    'Cyan Light',
    'Material 3 · cyan',
    Color(0xFF01C4FA),
    Brightness.light,
  ),
  materialDark(
    'Cyan Dark',
    'Material 3 · cyan',
    Color(0xFF01C4FA),
    Brightness.dark,
  ),
  violetLight(
    'Violet Light',
    'Material 3 · violet',
    Color(0xFF6750A4),
    Brightness.light,
  ),
  violetDark(
    'Violet Dark',
    'Material 3 · violet',
    Color(0xFF6750A4),
    Brightness.dark,
  ),
  forestLight(
    'Forest Light',
    'Material 3 · green',
    Color(0xFF006B5F),
    Brightness.light,
  ),
  forestDark(
    'Forest Dark',
    'Material 3 · green',
    Color(0xFF006B5F),
    Brightness.dark,
  );

  const ThemeSelection(
    this.label,
    this.description,
    this.seedColor,
    this.brightness,
  );
  final String label, description;
  final Color seedColor;
  final Brightness brightness;

  bool get dynamic => this == dynamicLight || this == dynamicDark;

  /// The same palette in [mode]; the original dark look has no light twin, so cyan stands in for it.
  ThemeSelection inBrightness(Brightness mode) {
    final (light, dark) = switch (this) {
      custom => (materialLight, custom),
      dynamicLight || dynamicDark => (dynamicLight, dynamicDark),
      materialLight || materialDark => (materialLight, materialDark),
      violetLight || violetDark => (violetLight, violetDark),
      forestLight || forestDark => (forestLight, forestDark),
    };
    return mode == Brightness.light ? light : dark;
  }
}

/// Which of a show's names the app shows.
enum TitleLanguage {
  auto('Automatic'),
  romaji('Romaji'),
  english('English');

  const TitleLanguage(this.label);
  final String label;
}

/// Rows of the home screen, in their default order.
enum HomeSection {
  featured('Featured', 'Trending shows at the top'),
  newEpisodes(
    'New episodes this week',
    "Episodes that aired in the past 7 days of shows you're watching",
  ),
  airing(
    'Continue watching · This season',
    "Shows you're watching that are airing",
  ),
  watching('Continue watching', 'The rest of your watching list'),
  planning('Plan to watch', 'Your planning list'),
  recent('Recently watched', 'Where you stopped, on this device'),
  jellyfin('On your Jellyfin', 'Added to your Jellyfin server lately'),
  season('This season', 'Popular shows this season'),
  trending('Trending now', 'Trending on AniList'),
  topRated('Top rated', 'Highest rated shows'),
  popular('All-time popular', 'The most popular shows'),
  upcoming('Coming soon', 'Upcoming anime'),
  action('Action', 'Popular action anime'),
  comedy('Comedy', 'Popular comedy anime'),
  fantasy('Fantasy', 'Popular fantasy anime'),
  romance('Romance', 'Popular romance anime'),
  sciFi('Sci-Fi', 'Popular science fiction anime');

  const HomeSection(this.label, this.description);
  final String label, description;

  SearchFilters? get filters => switch (this) {
    topRated => const SearchFilters(sort: 'SCORE_DESC'),
    popular => const SearchFilters(sort: 'POPULARITY_DESC'),
    upcoming => const SearchFilters(
      status: 'NOT_YET_RELEASED',
      sort: 'POPULARITY_DESC',
    ),
    action => const SearchFilters(genres: {'Action'}, sort: 'POPULARITY_DESC'),
    comedy => const SearchFilters(genres: {'Comedy'}, sort: 'POPULARITY_DESC'),
    fantasy => const SearchFilters(
      genres: {'Fantasy'},
      sort: 'POPULARITY_DESC',
    ),
    romance => const SearchFilters(
      genres: {'Romance'},
      sort: 'POPULARITY_DESC',
    ),
    sciFi => const SearchFilters(genres: {'Sci-Fi'}, sort: 'POPULARITY_DESC'),
    _ => null,
  };

  /// On until the user changes the sections; the rest start off.
  bool get byDefault => const {
    featured,
    airing,
    watching,
    jellyfin,
    season,
    trending,
  }.contains(this);
}

/// The player's picture modes, in the order its button cycles through them.
const pictureFits = {
  BoxFit.contain: 'Fit',
  BoxFit.cover: 'Fill (crop)',
  BoxFit.fill: 'Stretch',
};

/// User preferences; read synchronously after [load] runs at startup.
class Settings {
  static late SharedPreferences _prefs;
  static bool _loaded = false;

  static Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _loaded = true;
    // Continue watching started off before it was on by default; turn it on once for those who saved it off.
    if (!(_prefs.getBool('watching_on_migrated') ?? false)) {
      if (_prefs.getStringList('home_sections') case final saved?) {
        await _prefs.setStringList('home_sections', [
          for (final name in saved) name == '-watching' ? 'watching' : name,
        ]);
      }
      await _prefs.setBool('watching_on_migrated', true);
    }
  }

  /// The original AniView theme remains the default for existing installs.
  static ThemeSelection get themeSelection =>
      ThemeSelection.values.asNameMap()[_loaded
          ? _prefs.getString('theme_selection')
          : null] ??
      ThemeSelection.custom;
  static set themeSelection(ThemeSelection value) =>
      _prefs.setString('theme_selection', value.name);

  /// Use the chosen theme's light or dark twin to match the phone's own mode.
  static bool get followSystemTheme =>
      _loaded && (_prefs.getBool('follow_system_theme') ?? false);
  static set followSystemTheme(bool v) =>
      _prefs.setBool('follow_system_theme', v);

  /// The theme in effect: the chosen one, or its twin for the system's mode when following it.
  static ThemeSelection get activeTheme => followSystemTheme
      ? themeSelection.inBrightness(
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
        )
      : themeSelection;

  static bool get preferDub => _prefs.getBool('prefer_dub') ?? false;
  static set preferDub(bool v) => _prefs.setBool('prefer_dub', v);

  /// The version whose "What's new" the person has dismissed; null until they have (see [maybeShowWhatsNew]).
  static String? get changelogSeen => _prefs.getString('changelog_seen');
  static set changelogSeen(String? v) => v == null
      ? _prefs.remove('changelog_seen')
      : _prefs.setString('changelog_seen', v);

  /// The desktop window's last size and place.
  static Rect? get windowBounds {
    final v = _prefs.getStringList('window_bounds')?.map(double.parse).toList();
    return v == null ? null : Rect.fromLTWH(v[0], v[1], v[2], v[3]);
  }

  static set windowBounds(Rect? r) => r == null
      ? _prefs.remove('window_bounds')
      : _prefs.setStringList('window_bounds', [
          for (final v in [r.left, r.top, r.width, r.height]) '$v',
        ]);

  /// Last site explicitly selected (here or on a show); empty means the highest ranked site.
  static String get preferredSource =>
      _prefs.getString('preferred_source') ?? '';
  static set preferredSource(String v) =>
      _prefs.setString('preferred_source', v);

  static bool get resume => _prefs.getBool('resume') ?? true;
  static set resume(bool v) => _prefs.setBool('resume', v);

  static bool get autoNext => _prefs.getBool('auto_next') ?? true;
  static set autoNext(bool v) => _prefs.setBool('auto_next', v);

  static SkipMode get skipMode =>
      SkipMode.values.asNameMap()[_prefs.getString('skip_mode')] ??
      SkipMode.button;
  static set skipMode(SkipMode v) => _prefs.setString('skip_mode', v.name);

  /// Swipe to seek, and to change brightness (left) or volume (right).
  static bool get swipeGestures => _prefs.getBool('swipe_gestures') ?? false;
  static set swipeGestures(bool v) => _prefs.setBool('swipe_gestures', v);

  static int get seekSeconds => _prefs.getInt('seek_seconds') ?? 10;
  static set seekSeconds(int v) => _prefs.setInt('seek_seconds', v);

  /// Length of the fixed skip button, for shows AniSkip has no times for.
  static int get skipSeconds => _prefs.getInt('skip_seconds') ?? 85;
  static set skipSeconds(int v) => _prefs.setInt('skip_seconds', v);

  /// Hand episodes to another video app (MX Player, VLC, …) instead of the built-in player.
  static bool get externalPlayer => _prefs.getBool('external_player') ?? false;
  static set externalPlayer(bool v) => _prefs.setBool('external_player', v);

  /// Decoded frames go straight to the screen instead of through the GPU: much smoother on TV chips, but a few
  /// devices' decoders show a black picture with it.
  // Off by default: on some TVs mpv's embedded output shows no picture at all.

  static double get speed => _prefs.getDouble('speed') ?? 1.0;

  /// What holding the video does: 'speed' (2× while held), 'pause' (paused while held) or 'off'.
  static String get holdGesture => _prefs.getString('hold_gesture') ?? 'speed';
  static set holdGesture(String v) => _prefs.setString('hold_gesture', v);
  static set speed(double v) => _prefs.setDouble('speed', v);

  /// How the picture fills the screen when an episode starts.
  static BoxFit get videoFit =>
      pictureFits.keys.asNameMap()[_prefs.getString('video_fit')] ??
      BoxFit.contain;
  static set videoFit(BoxFit v) => _prefs.setString('video_fit', v.name);

  /// Subtitle track to pick by label prefix ("English", "Spanish", …); "Off" disables subtitles.
  static String get subtitleLanguage =>
      _prefs.getString('subtitle_language') ?? 'English';
  static set subtitleLanguage(String v) =>
      _prefs.setString('subtitle_language', v);

  static double get subtitleSize => _prefs.getDouble('subtitle_size') ?? 22;
  static set subtitleSize(double v) => _prefs.setDouble('subtitle_size', v);

  /// Search's shortcut on a desktop: the key's id and its modifiers; null for Ctrl+F (see [searchShortcut]).
  static List<String>? get searchShortcut =>
      _prefs.getStringList('search_shortcut');
  static set searchShortcut(List<String>? v) => v == null
      ? _prefs.remove('search_shortcut')
      : _prefs.setStringList('search_shortcut', v);

  /// The greeting when the app opens (see [Welcome]), and the account name it last greeted.
  /// Automatic: English on TV, else the AniList account's own choice.
  static TitleLanguage get titleLanguage =>
      TitleLanguage.values.asNameMap()[_loaded
          ? _prefs.getString('title_language')
          : null] ??
      TitleLanguage.auto;
  static set titleLanguage(TitleLanguage v) =>
      _prefs.setString('title_language', v.name);

  static bool get welcome => _prefs.getBool('welcome') ?? true;
  static set welcome(bool v) => _prefs.setBool('welcome', v);
  static String? get welcomeName => _prefs.getString('welcome_name');
  static set welcomeName(String? v) => v == null
      ? _prefs.remove('welcome_name')
      : _prefs.setString('welcome_name', v);

  static bool get syncAniList => _prefs.getBool('sync_anilist') ?? true;
  static set syncAniList(bool v) => _prefs.setBool('sync_anilist', v);

  static int get watchedPercent => _prefs.getInt('watched_percent') ?? 85;
  static set watchedPercent(int v) => _prefs.setInt('watched_percent', v);

  /// Ecchi shows out of browse and search (adult ones never show); on by default on a shared TV.
  /// 'auto' (the TV layout on TVs), 'phone' or 'tv'.
  static String get layout => _prefs.getString('layout') ?? 'auto';
  static set layout(String v) => _prefs.setString('layout', v);

  /// Beta builds: Flutter's frame graph over the app (top: UI thread, bottom: raster thread; a red bar is a slow frame).
  static bool get perfOverlay =>
      isBetaBuild && (_prefs.getBool('perf_overlay') ?? false);
  static set perfOverlay(bool v) => _prefs.setBool('perf_overlay', v);

  static bool get hideNsfw => _prefs.getBool('hide_nsfw') ?? isTv;
  static set hideNsfw(bool v) => _prefs.setBool('hide_nsfw', v);

  static bool get newestFirst => _prefs.getBool('newest_first') ?? true;
  static set newestFirst(bool v) => _prefs.setBool('newest_first', v);

  /// Where Watch random picks from: 'planning' (your Planning list, else everything) or 'everything'.
  static String get randomFrom => _prefs.getString('random_from') ?? 'planning';
  static set randomFrom(String v) => _prefs.setString('random_from', v);

  /// Tallest video height to stream; 0 means the best the connection allows.
  static int get streamQuality => _prefs.getInt('stream_quality') ?? 0;
  static set streamQuality(int v) => _prefs.setInt('stream_quality', v);

  /// Tallest video height to download; 0 means the best available.
  static int get downloadQuality => _prefs.getInt('download_quality') ?? 0;
  static set downloadQuality(int v) => _prefs.setInt('download_quality', v);

  /// Also copy finished downloads to the phone's gallery (Movies/AniView) as MP4.
  static bool get saveToGallery => _prefs.getBool('save_to_gallery') ?? false;
  static set saveToGallery(bool v) => _prefs.setBool('save_to_gallery', v);

  static bool get episodeNotifications =>
      _prefs.getBool('episode_notifications') ?? true;
  static set episodeNotifications(bool v) =>
      _prefs.setBool('episode_notifications', v);

  /// Last time the home release inbox was opened, in Unix seconds.
  static int get releaseSeenAt => _prefs.getInt('release_seen_at') ?? 0;
  static set releaseSeenAt(int v) => _prefs.setInt('release_seen_at', v);

  /// Android document tree picked for new offline episodes, used only while saving to the gallery is on. Empty uses app storage.
  /// Desktop: the folder the downloads are kept in (an "AniView" folder is made inside it); empty is the app's own.
  static String get desktopDownloadFolder =>
      _prefs.getString('desktop_download_folder') ?? '';
  static set desktopDownloadFolder(String v) =>
      _prefs.setString('desktop_download_folder', v);

  /// The Jellyfin server signed in to (see jellyfin.dart); no token is signed out.
  static String get jellyfinServer => _prefs.getString('jellyfin_server') ?? '';
  static set jellyfinServer(String v) => _prefs.setString('jellyfin_server', v);
  static String get jellyfinToken =>
      (_loaded ? _prefs.getString('jellyfin_token') : null) ?? '';
  static set jellyfinToken(String v) => _prefs.setString('jellyfin_token', v);
  static String get jellyfinUser => _prefs.getString('jellyfin_user') ?? '';
  static set jellyfinUser(String v) => _prefs.setString('jellyfin_user', v);
  static String get jellyfinUserName =>
      _prefs.getString('jellyfin_user_name') ?? '';
  static set jellyfinUserName(String v) =>
      _prefs.setString('jellyfin_user_name', v);

  /// The Jellyseerr signed in to (see jellyseerr.dart); no cookie is signed out.
  static String get jellyseerrServer =>
      _prefs.getString('jellyseerr_server') ?? '';
  static set jellyseerrServer(String v) =>
      _prefs.setString('jellyseerr_server', v);
  static String get jellyseerrCookie =>
      (_loaded ? _prefs.getString('jellyseerr_cookie') : null) ?? '';
  static set jellyseerrCookie(String v) =>
      _prefs.setString('jellyseerr_cookie', v);

  /// The Dantotsu comments session (see dantotsu.dart): its token, when it was issued, and whose it is.
  static String get dantotsuToken => _prefs.getString('dantotsu_token') ?? '';
  static set dantotsuToken(String v) => _prefs.setString('dantotsu_token', v);
  static int get dantotsuTokenAt => _prefs.getInt('dantotsu_token_at') ?? 0;
  static set dantotsuTokenAt(int v) => _prefs.setInt('dantotsu_token_at', v);
  static String get dantotsuUser => _prefs.getString('dantotsu_user') ?? '';
  static set dantotsuUser(String v) => _prefs.setString('dantotsu_user', v);
  static String get dantotsuUserName =>
      _prefs.getString('dantotsu_user_name') ?? '';
  static set dantotsuUserName(String v) =>
      _prefs.setString('dantotsu_user_name', v);

  /// Whether the Dantotsu comment rules were agreed to, which posting waits for.
  static bool get dantotsuRulesAccepted =>
      _prefs.getBool('dantotsu_rules') ?? false;
  static set dantotsuRulesAccepted(bool v) =>
      _prefs.setBool('dantotsu_rules', v);

  /// Whether the show's main button and the player's next episode pass over filler (see filler.dart).
  static bool get skipFiller => _prefs.getBool('skip_filler') ?? false;
  static set skipFiller(bool v) => _prefs.setBool('skip_filler', v);

  /// This install's id on the server, made once: Jellyfin keeps one session per device.
  static String get jellyfinDevice {
    if (_prefs.getString('jellyfin_device') case final id?) return id;
    final id = List.generate(
      16,
      (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _prefs.setString('jellyfin_device', id);
    return id;
  }

  static String get downloadFolder => _prefs.getString('download_folder') ?? '';
  static set downloadFolder(String v) => _prefs.setString('download_folder', v);

  static String get downloadFolderLabel {
    if (downloadFolder.isEmpty) {
      return 'App storage · choose a folder for new episodes';
    }
    final location = Uri.parse(downloadFolder).pathSegments.last;
    return location.startsWith('primary:')
        ? location.replaceFirst('primary:', 'Internal storage/')
        : location.replaceFirst(':', '/');
  }

  static bool get analytics => _prefs.getBool('analytics') ?? true;
  static set analytics(bool v) => _prefs.setBool('analytics', v);

  /// Random per-install id for counting users without fingerprinting them.
  static String get installId =>
      _prefs.getString('install_id') ??
      (() {
        final random = Random.secure();
        final id = [
          for (var i = 0; i < 16; i++)
            random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ].join();
        _prefs.setString('install_id', id);
        return id;
      })();

  /// Keys of the phones paired as this TV's remote (base64).
  static List<String> get remoteKeys =>
      _prefs.getStringList('remote_keys') ?? const [];
  static set remoteKeys(List<String> v) =>
      _prefs.setStringList('remote_keys', v);

  /// TVs this phone is a remote for: TV id → {key, name, address}.
  static Map<String, dynamic> get tvRemotes =>
      jsonDecode(_prefs.getString('tv_remotes') ?? '{}');
  static set tvRemotes(Map<String, dynamic> v) =>
      _prefs.setString('tv_remotes', jsonEncode(v));

  /// Newest first.
  static List<String> get recentSearches =>
      _prefs.getStringList('recent_searches') ?? const [];
  static set recentSearches(List<String> v) =>
      _prefs.setStringList('recent_searches', v.take(10).toList());

  /// Every home section in the chosen order, with whether it's shown.
  static List<(HomeSection, bool)> get homeSections {
    final saved = [
      for (final name in _prefs.getStringList('home_sections') ?? const [])
        if (HomeSection.values.asNameMap()[name.replaceFirst('-', '')]
            case final section?)
          (section, !name.startsWith('-')),
    ];
    return [
      ...saved,
      // Sections added in an update show up, at the end.
      for (final section in HomeSection.values)
        if (!saved.any((s) => s.$1 == section)) (section, section.byDefault),
    ];
  }

  static set homeSections(List<(HomeSection, bool)> v) => _prefs.setStringList(
    'home_sections',
    [for (final (section, shown) in v) '${shown ? '' : '-'}${section.name}'],
  );

  static bool get episodeTipSeen => _prefs.getBool('episode_tip_seen') ?? false;
  static set episodeTipSeen(bool v) => _prefs.setBool('episode_tip_seen', v);
}

/// App version and opening links in the browser, answered by MainActivity.

const _releases =
    'https://api.github.com/repos/ebrahimHakimuddin/aniview/releases';
const isBetaBuild = bool.fromEnvironment('ANIVIEW_BETA');

/// What this build is called: the beta installs beside AniView as an app of its own.
const appName = isBetaBuild ? 'AniView Beta' : 'AniView';

/// Whether release tag [latest] ("v1.5.2", "v2.6.0-beta.2") is a newer version than [current] ("1.5.1"). A
/// release is newer than its own betas, and betas go by their number.
bool isNewerVersion(String latest, String current) {
  (List<int>, List<int>?) parts(String v) {
    final [core, ...pre] = v.replaceFirst('v', '').split('+').first.split('-');
    List<int> numbers(String s) => [
      for (final p in s.split('.')) int.tryParse(p) ?? 0,
    ];
    return (
      numbers(core),
      pre.isEmpty
          ? null
          : numbers(pre.join('-').replaceAll(RegExp(r'[^0-9.]'), '')),
    );
  }

  int compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  final (a, aBeta) = parts(latest);
  final (b, bBeta) = parts(current);
  final order = compare(a, b);
  if (order != 0) return order > 0;
  if (aBeta == null || bBeta == null) return aBeta == null && bBeta != null;
  return compare(aBeta, bBeta) > 0;
}

/// This build's download among a release's [assets]: the APK for [abi] on Android, else the platform's installer;
/// a beta's own names in a beta build. Null when the release has none.
Map? updateAsset(
  List assets, {
  String? abi,
  String os = '',
  bool beta = isBetaBuild,
}) {
  final prefix = beta ? 'AniView-Beta-' : 'AniView-';
  final name = switch (os.isEmpty ? Platform.operatingSystem : os) {
    'android' when abi != null =>
      beta ? 'AniView-Beta-$abi.apk' : 'app-$abi-release.apk',
    'windows' => '${prefix}windows-x64-setup.exe',
    'macos' => '${prefix}macos.dmg',
    'linux' => '${prefix}x86_64.AppImage',
    _ => null,
  };
  return assets.cast<Map>().where((a) => a['name'] == name).firstOrNull;
}

/// The newest release for this build: a beta follows the betas (pre-releases, which install as their own app), the
/// stable app the releases.
Future<Map?> _newestRelease() async {
  final res = await http
      .get(
        Uri.parse(isBetaBuild ? '$_releases?per_page=20' : '$_releases/latest'),
      )
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) throw HttpException('${res.statusCode}');
  final json = jsonDecode(res.body);
  if (!isBetaBuild) return json as Map;
  return (json as List)
      .cast<Map>()
      .where((r) => r['prerelease'] == true && r['draft'] != true)
      .firstOrNull;
}

/// Offers the newest release when it is newer than this build, and installs it from inside the app where the
/// platform lets an app do that (everywhere but iOS, and Linux outside an AppImage, which open the release page).
/// [quiet] (the check on launch) stays silent when up to date or offline.
Future<void> checkForUpdate(BuildContext context, {bool quiet = false}) async {
  if (Platform.isIOS) return; // sideloaded: the sideloading app updates it
  try {
    final current = await AndroidApp.version() ?? '';
    final release = await _newestRelease();
    if (!context.mounted) return;
    if (release == null || !isNewerVersion(release['tag_name'], current)) {
      if (!quiet) showSuccess(context, 'You have the latest version');
      return;
    }
    final version = (release['tag_name'] as String).replaceFirst('v', '');
    final asset = Platform.isLinux && Platform.environment['APPIMAGE'] == null
        ? null
        : updateAsset(
            release['assets'] as List? ?? const [],
            abi: await AndroidApp.abi(),
          );
    if (!context.mounted) return;
    Future<void> update() async {
      try {
        Analytics.event('app_update', {'from': current, 'to': version});
        if (asset == null) return await AndroidApp.open(release['html_url']);
        final file = await showDialog<File>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _UpdateDownload(
            asset['browser_download_url'],
            asset['name'],
            version,
          ),
        );
        if (file != null && context.mounted) await _install(context, file);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    // A snackbar's action is out of the remote's reach on TV.
    if (isTv) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => PanelDialog(
          title: Text('$appName $version is available'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Later'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      if (go == true) await update();
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          showCloseIcon: true,
          content: Text('$appName $version is available'),
          action: SnackBarAction(label: 'Update', onPressed: update),
        ),
      );
  } catch (e) {
    if (!quiet && context.mounted) showError(context, e);
  }
}

/// Puts the downloaded update in place of this version: Android's installer; on Windows the installer, run quietly
/// once this has closed, which opens the new version; on Linux the new AppImage swapped in for this one and started.
/// macOS's sandbox keeps the app from replacing itself, so its disk image opens to drag the app from.
Future<void> _install(BuildContext context, File file) async {
  switch (Platform.operatingSystem) {
    case 'android':
      if (!await AndroidApp.installApk(file.path) && context.mounted) {
        showSuccess(context, 'Allow AniView to install apps, then come back');
      }
    case 'windows':
      await Process.start(file.path, [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
      ], mode: ProcessStartMode.detached);
      exit(0);
    case 'linux':
      final appImage = Platform.environment['APPIMAGE']!;
      // Copied beside it first, so the swap is one rename and a failed copy leaves this version working.
      final next = await file.copy('$appImage.update');
      await Process.run('chmod', ['755', next.path]);
      await next.rename(appImage);
      await Process.start(appImage, const [], mode: ProcessStartMode.detached);
      exit(0);
    case 'macos':
      final opened = await Process.run('open', [file.path]);
      if (opened.exitCode != 0) throw Exception('Could not open the update');
      if (!context.mounted) return;
      final quit = await showDialog<bool>(
        context: context,
        builder: (context) => PanelDialog(
          title: const Text('Drag $appName into Applications'),
          content: const Text(
            'Replace the one there, then open $appName again. Quit this one first so it can be replaced.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Later'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Quit $appName'),
            ),
          ],
        ),
      );
      if (quit == true) exit(0);
  }
}

/// Downloads the update with its progress showing; pops with the file, or null when cancelled.
class _UpdateDownload extends StatefulWidget {
  const _UpdateDownload(this.url, this.name, this.version);

  final String url, name, version;

  @override
  State<_UpdateDownload> createState() => _UpdateDownloadState();
}

class _UpdateDownloadState extends State<_UpdateDownload> {
  final client = http.Client();
  double? progress;
  Object? error;

  @override
  void initState() {
    super.initState();
    _download();
  }

  @override
  void dispose() {
    client.close(); // cancelling stops the download
    super.dispose();
  }

  Future<void> _download() async {
    try {
      final res = await client.send(http.Request('GET', Uri.parse(widget.url)));
      if (res.statusCode != 200) {
        throw HttpException('Download failed (${res.statusCode})');
      }
      final file = File(
        '${(await getTemporaryDirectory()).path}/${widget.name}',
      );
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          final total = res.contentLength ?? 0;
          if (total > 0 && mounted) setState(() => progress = received / total);
        }
      } finally {
        await sink.close();
      }
      if (mounted) Navigator.pop(context, file);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => PanelDialog(
    title: Text('Updating to ${widget.version}'),
    content: error != null
        ? Text(friendlyError(error!))
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text(
                progress == null
                    ? 'Downloading…'
                    : 'Downloading · ${(progress! * 100).round()}%',
              ),
            ],
          ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context),
        child: Text(error != null ? 'Close' : 'Cancel'),
      ),
    ],
  );
}

const _randomFrom = {'planning': 'Planning list', 'everything': 'Anything'};

const _holdGestures = {
  'speed': 'Play at 2×',
  'pause': 'Pause until released',
  'off': 'Do nothing',
};

const _qualities = {0: 'Best', 1080: '1080p', 720: '720p', 480: '480p'};

const subtitleLanguages = [
  'Off',
  'English',
  'Spanish',
  'Portuguese',
  'French',
  'German',
  'Italian',
  'Arabic',
  'Russian',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Analytics.screen('/settings', title: 'Settings');
  }

  Future<void> _choose<T>(
    String title,
    Map<T, String> options,
    T current,
    void Function(T) apply,
  ) async {
    final picked = await pickOne(context, title, options, current);
    if (picked != null) setState(() => apply(picked));
  }

  Future<void> _pickTheme() async {
    // Your colors only where Android has a wallpaper palette to give.
    // Following the system, only the twins for its current mode are offered; picking one still covers both.
    final mode = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final themes = [
      for (final choice in ThemeSelection.values)
        if ((!choice.dynamic || systemAccent != null) &&
            (!Settings.followSystemTheme ||
                choice == ThemeSelection.custom ||
                choice.brightness == mode))
          choice,
    ];
    final picked = await showSheet<ThemeSelection>(
      context,
      height: .72,
      (sheet) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sheetTitle(sheet, 'Choose a theme'),
            Expanded(
              child: ListView.builder(
                itemCount: themes.length,
                itemBuilder: (context, index) {
                  final choice = themes[index];
                  final colors = themeScheme(choice);
                  final selected = choice == Settings.activeTheme;
                  return ScrollIntoViewOnFocus(
                    child: ListTile(
                      autofocus: selected,
                      selected: selected,
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: Stack(
                          children: [
                            Positioned(
                              left: 1,
                              top: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.surface,
                                  border: Border.all(color: colors.outline),
                                ),
                                child: const SizedBox.square(dimension: 34),
                              ),
                            ),
                            Positioned(
                              right: 1,
                              bottom: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.primary,
                                ),
                                child: const SizedBox.square(dimension: 26),
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(choice.label),
                      subtitle: Text(choice.description),
                      trailing: selected
                          ? const Icon(Icons.check_circle_rounded)
                          : null,
                      onTap: () => Navigator.pop(sheet, choice),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null || picked == Settings.themeSelection) return;
    setState(() => Settings.themeSelection = picked);
    themeGeneration.value++;
  }

  /// Desktop: keep the downloads in [folder] (the app's own when null), and say why when that can't be done.
  Future<void> _moveDownloads(String? folder) async {
    try {
      await Downloads.instance.moveTo(folder);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(String title, String message, String action) =>
      confirmDestructive(
        context,
        title: title,
        message: message,
        action: action,
      );

  Future<void> _signIn(ListProvider provider) async {
    try {
      final name = await Tracker.signIn(context, provider);
      if (mounted && name != null) showSuccess(context, 'Signed in as $name');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _jellyfinSignIn() async {
    final server = TextEditingController(text: Settings.jellyfinServer);
    final name = TextEditingController(text: Settings.jellyfinUserName);
    final password = TextEditingController();
    final how = await showDialog<String>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Connect to Jellyfin'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: server,
                autofocus: true,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'http://192.168.1.10:8096',
                ),
              ),
              TextField(
                controller: name,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => Navigator.pop(context, 'password'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          // No typing a password with a remote: approve this device from a Jellyfin app already signed in.
          TextButton(
            onPressed: () => Navigator.pop(context, 'quick'),
            child: const Text('Quick Connect'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'password'),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (how == null) return;
    try {
      if (how == 'quick') {
        if (!await _quickConnect(server.text)) return;
      } else {
        await Jellyfin.signIn(server.text, name.text, password.text);
      }
      Sites.reload();
      if (mounted) {
        showSuccess(context, 'Connected as ${Settings.jellyfinUserName}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _jellyseerrSignIn() async {
    final server = TextEditingController(text: Settings.jellyseerrServer);
    final name = TextEditingController(text: Settings.jellyfinUserName);
    final password = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Connect to Jellyseerr'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: server,
                autofocus: true,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                decoration: const InputDecoration(
                  labelText: 'Jellyseerr address',
                  hintText: 'http://192.168.1.10:5055',
                ),
              ),
              TextField(
                controller: name,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Jellyfin username',
                ),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Jellyfin password',
                ),
                onSubmitted: (_) => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await Jellyseerr.signIn(server.text, name.text, password.text);
      if (mounted) showSuccess(context, 'Connected to Jellyseerr');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  /// Shows Quick Connect's code until it's approved (true) or the dialog is closed (false).
  Future<bool> _quickConnect(String server) async {
    final code = ValueNotifier<String?>(null);
    var open = true;
    final dialog = showDialog<void>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Quick Connect'),
        content: ValueListenableBuilder(
          valueListenable: code,
          builder: (context, value, _) => value == null
              ? const LinearProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'In a Jellyfin app you\'re signed in to, open Quick Connect and enter this code',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.displaySmall
                          ?.copyWith(letterSpacing: 8),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ).whenComplete(() => open = false);
    try {
      return await Jellyfin.quickConnect(
        server,
        showCode: (value) => code.value = value,
        cancelled: () => !open,
      );
    } finally {
      if (open && mounted) Navigator.pop(context);
      await dialog;
      code.dispose();
    }
  }

  Future<void> _signOut(ListProvider provider) async {
    await Tracker.signOut(provider);
    if (!mounted) return;
    setState(() {});
    showSuccess(context, 'Signed out of ${provider.name}');
  }

  int _page = 0;

  /// Desktop: the groups down the left, the one you picked filling the right, so no scrolling past the rest.
  Widget _desktop(List<Widget> sections) {
    final text = Theme.of(context).textTheme;
    final groups = [
      for (final w in sections)
        if (w is _Group) w,
    ];
    // The account, then each group; a page is picked by its place.
    final titles = ['Account', for (final g in groups) g.title];
    final page = _page.clamp(0, titles.length - 1);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 240,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 28, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: Text('Settings', style: text.headlineMedium),
              ),
              for (final (i, title) in titles.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    dense: true,
                    selected: i == page,
                    selectedTileColor: scheme.primary.withValues(alpha: .16),
                    selectedColor: scheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    title: Text(title),
                    onTap: () => setState(() => _page = i),
                  ),
                ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: hairline),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 48),
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: page == 0 ? sections.first : groups[page - 1],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      Column(
        children: [
          for (final p in [Tracker.anilist, Tracker.mal])
            if (p.usable)
              _Account(
                provider: p,
                other: Tracker.account == p ? null : Tracker.account,
                onSignIn: () => _signIn(p),
                onSignOut: () => _signOut(p),
              ),
        ],
      ),
      _Group('Appearance', [
        ListTile(
          title: const Text('Theme'),
          subtitle: Text(Settings.activeTheme.label),
          onTap: _pickTheme,
        ),
        _Choice(
          title: 'Show titles in',
          value: Settings.titleLanguage.label,
          onTap: () => _choose(
            'Show titles in',
            {for (final l in TitleLanguage.values) l: l.label},
            Settings.titleLanguage,
            (v) {
              Settings.titleLanguage = v;
              // Every screen, the ones under this one too, names its shows again; nothing else is reset.
              void rebuild(Element e) => e
                ..markNeedsBuild()
                ..visitChildren(rebuild);
              WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
            },
          ),
        ),
        SwitchListTile(
          title: const Text('Welcome screen'),
          subtitle: const Text('Greets you by name when AniView opens'),
          value: Settings.welcome,
          onChanged: (v) => setState(() => Settings.welcome = v),
        ),
        SwitchListTile(
          title: const Text('Follow system light and dark'),
          subtitle: Text(
            'Uses the light or dark version of this theme to match your ${isDesktop ? 'computer' : 'phone'}',
          ),
          value: Settings.followSystemTheme,
          onChanged: (v) {
            setState(() => Settings.followSystemTheme = v);
            themeGeneration.value++;
          },
        ),
        if (isBetaBuild)
          SwitchListTile(
            title: const Text('Performance overlay'),
            subtitle: const Text(
              'Frame graph: top is the UI thread, bottom the raster thread. Red bars are slow frames',
            ),
            value: Settings.perfOverlay,
            onChanged: (v) {
              setState(() => Settings.perfOverlay = v);
              themeGeneration.value++; // the app rebuilds to show or hide it
            },
          ),
      ]),
      _Group('Tracking', [
        SwitchListTile(
          title: const Text('Update progress automatically'),
          subtitle: const Text('Marks the episode watched on your tracker'),
          value: Settings.syncAniList,
          onChanged: (v) => setState(() => Settings.syncAniList = v),
        ),
        _Choice(
          title: 'Count as watched at',
          value: '${Settings.watchedPercent}%',
          onTap: () => _choose(
            'Count as watched at',
            {
              for (final p in const [50, 60, 70, 75, 80, 85, 90, 95]) p: '$p%',
            },
            Settings.watchedPercent,
            (v) => Settings.watchedPercent = v,
          ),
        ),
      ]),
      _Group('Jellyfin', [
        if (Settings.jellyfinToken.isEmpty)
          ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: const Text('Connect to Jellyfin'),
            subtitle: const Text(
              'Play shows from your own server, listed first among the sites',
            ),
            onTap: _jellyfinSignIn,
          )
        else
          ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: Text('Connected as ${Settings.jellyfinUserName}'),
            subtitle: Text(Settings.jellyfinServer),
            trailing: TextButton(
              onPressed: () {
                Jellyfin.signOut();
                Sites.reload();
                setState(() {});
              },
              child: const Text('Disconnect'),
            ),
          ),
        if (Settings.jellyseerrCookie.isEmpty)
          ListTile(
            leading: const Icon(Icons.playlist_add_rounded),
            title: const Text('Connect to Jellyseerr'),
            subtitle: const Text(
              'Request shows that aren\'t on your server yet. Works with Seerr too',
            ),
            onTap: _jellyseerrSignIn,
          )
        else
          ListTile(
            leading: const Icon(Icons.playlist_add_check_rounded),
            title: const Text('Jellyseerr connected'),
            subtitle: Text(Settings.jellyseerrServer),
            trailing: TextButton(
              onPressed: () => setState(Jellyseerr.signOut),
              child: const Text('Disconnect'),
            ),
          ),
      ]),
      if (isDesktop)
        _Group('Keyboard', [
          ListTile(
            leading: const Icon(Icons.keyboard_rounded),
            title: const Text('Search shortcut'),
            subtitle: Text(keysLabel(searchShortcut.value)),
            trailing: Settings.searchShortcut == null
                ? null
                : IconButton(
                    tooltip: 'Back to $shortcutKey+F',
                    icon: const Icon(Icons.restore_rounded),
                    onPressed: () => setState(() => rebindSearch(null)),
                  ),
            onTap: () async {
              final keys = await recordShortcut(context);
              if (keys != null) setState(() => rebindSearch(keys));
            },
          ),
        ]),
      _Group('Home screen', [
        _Choice(
          title: 'Watch random picks from',
          value: _randomFrom[Settings.randomFrom] ?? 'Planning list',
          onTap: () => _choose(
            'Watch random picks from',
            const {
              'planning': 'Planning list · anything when it’s empty',
              'everything': 'Anything popular you haven’t watched',
            },
            Settings.randomFrom,
            (v) => Settings.randomFrom = v,
          ),
        ),
        if (!isDesktop && !Platform.isIOS)
          ListTile(
            title: const Text('Layout'),
            subtitle: Text(
              const {
                'auto': 'Automatic · TV layout on TVs',
                'phone': 'Phone',
                'tv': 'TV · for a remote or keyboard, in landscape',
              }[Settings.layout]!,
            ),
            onTap: () async {
              final picked = await pickOne(context, 'Layout', const {
                'auto': 'Automatic',
                'phone': 'Phone',
                'tv': 'TV',
              }, Settings.layout);
              if (picked == null || picked == Settings.layout) return;
              Settings.layout = picked;
              applyLayout(picked);
              appGeneration.value++; // rebuilt in the new layout
            },
          ),
        ListTile(
          title: const Text('Sections'),
          subtitle: const Text('Choose and reorder the rows on home'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const _HomeSectionsScreen()),
          ),
        ),
        SwitchListTile(
          title: const Text('Hide NSFW shows'),
          subtitle: const Text('Keeps ecchi titles out of browse and search'),
          value: Settings.hideNsfw,
          onChanged: (v) => setState(() => Settings.hideNsfw = v),
        ),
      ]),
      // A phone that has never paired a TV sets one up; "remote" only once there's a TV to control.
      if (!Platform.isIOS)
        _Group(isTv ? 'Remote' : 'TV', [
          ListTile(
            leading: Icon(
              isTv || Settings.tvRemotes.isNotEmpty
                  ? Icons.settings_remote_rounded
                  : Icons.connected_tv_rounded,
            ),
            title: Text(
              isTv
                  ? 'Phone remote'
                  : Settings.tvRemotes.isEmpty
                  ? 'Set up AniView on a TV'
                  : 'TV remote',
            ),
            subtitle: Text(
              isTv
                  ? 'Control AniView on this TV from your phone'
                  : Settings.tvRemotes.isEmpty
                  ? isDesktop
                        ? 'Pair a TV running AniView to sign it in from this computer and use it as the TV\'s remote'
                        : 'Pair a TV running AniView to sign it in from this phone and use the phone as its remote'
                  : 'Control AniView on ${Settings.tvRemotes.length == 1 ? Settings.tvRemotes.values.first['name'] : 'your TVs'}',
            ),
            onTap: () async {
              await pushSettled(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      isTv ? const TvPairScreen() : const PhoneRemoteScreen(),
                ),
              );
              // Pairing may have signed the TV in.
              if (mounted) setState(() {});
            },
          ),
        ]),
      if (Platform.isAndroid)
        _Group('Notifications', [
          SwitchListTile(
            title: const Text('New episodes'),
            subtitle: const Text(
              'When a show you\'re watching or recently watched airs',
            ),
            value: Settings.episodeNotifications,
            onChanged: (v) {
              setState(() => Settings.episodeNotifications = v);
              // The schedule itself is refreshed by home when Settings closes.
              if (v) EpisodeNotifications.requestPermission(again: true);
            },
          ),
        ]),
      _Group('Playback', [
        SwitchListTile(
          title: const Text('Skip filler episodes'),
          subtitle: const Text(
            'Up next and the next episode pass over filler (from Anime Filler List). Filler stays in the list, marked',
          ),
          value: Settings.skipFiller,
          onChanged: (v) => setState(() => Settings.skipFiller = v),
        ),
        _Choice(
          title: 'Preferred audio',
          value: Settings.preferDub ? 'Dub' : 'Sub',
          onTap: () => _choose(
            'Preferred audio',
            const {false: 'Sub (Japanese audio)', true: 'Dub (English audio)'},
            Settings.preferDub,
            (v) => Settings.preferDub = v,
          ),
        ),
        FutureBuilder(
          future: Sites.all(),
          builder: (context, snap) => _Choice(
            title: 'Preferred source',
            value: Settings.preferredSource.isEmpty
                ? 'Highest ranked'
                : Settings.preferredSource,
            onTap: () => _choose(
              'Preferred source',
              {
                '': 'Highest ranked',
                for (final s in snap.data ?? const <Source>[]) s.name: s.label,
              },
              Settings.preferredSource,
              (v) => Settings.preferredSource = v,
            ),
          ),
        ),
        if (Platform.isAndroid)
          ListTile(
            title: const Text('Extensions'),
            subtitle: const Text('More sites, from Aniyomi extension repos'),
            onTap: () async {
              await pushSettled(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const ExtensionsScreen(),
                ),
              );
              // Installed extensions join the sources above.
              if (mounted) setState(() {});
            },
          ),
        _Choice(
          title: 'Streaming quality',
          subtitle: 'Change it for one episode in the player',
          value: _qualities[Settings.streamQuality] ?? 'Best',
          onTap: () => _choose(
            'Streaming quality',
            _qualities,
            Settings.streamQuality,
            (v) => Settings.streamQuality = v,
          ),
        ),
        SwitchListTile(
          title: const Text('Resume where you left off'),
          value: Settings.resume,
          onChanged: (v) => setState(() => Settings.resume = v),
        ),
        SwitchListTile(
          title: const Text('Play next episode automatically'),
          value: Settings.autoNext,
          onChanged: (v) => setState(() => Settings.autoNext = v),
        ),
        _Choice(
          title: 'Skip intro & outro',
          subtitle: 'Timestamps from AniSkip',
          value: const {
            SkipMode.button: 'Show button',
            SkipMode.auto: 'Automatically',
            SkipMode.off: 'Off',
          }[Settings.skipMode]!,
          onTap: () => _choose(
            'Skip intro & outro',
            const {
              SkipMode.button: 'Show a skip button',
              SkipMode.auto: 'Skip automatically',
              SkipMode.off: 'Off',
            },
            Settings.skipMode,
            (v) => Settings.skipMode = v,
          ),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('Use an external player'),
            subtitle: const Text(
              'Play episodes in MX Player, VLC or another installed app',
            ),
            value: Settings.externalPlayer,
            onChanged: (v) => setState(() => Settings.externalPlayer = v),
          ),
        if (!isTv && !isDesktop)
          SwitchListTile(
            title: const Text('Swipe gestures'),
            subtitle: const Text(
              'Swipe to seek, brightness on the left, volume on the right',
            ),
            value: Settings.swipeGestures,
            onChanged: (v) => setState(() => Settings.swipeGestures = v),
          ),
        if (!isTv && !isDesktop)
          _Choice(
            title: 'Hold the video to',
            value: _holdGestures[Settings.holdGesture] ?? 'Play at 2×',
            onTap: () => _choose(
              'Hold the video to',
              _holdGestures,
              Settings.holdGesture,
              (v) => Settings.holdGesture = v,
            ),
          ),
        _Choice(
          title: isTv || isDesktop
              ? 'Left / right seeks'
              : 'Double-tap to seek',
          value: '${Settings.seekSeconds}s',
          onTap: () => _choose(
            isTv || isDesktop ? 'Left / right seeks' : 'Double-tap to seek',
            {
              for (final s in const [5, 10, 15, 30]) s: '$s seconds',
            },
            Settings.seekSeconds,
            (v) => Settings.seekSeconds = v,
          ),
        ),
        _Choice(
          title: 'Skip button length',
          value: '${Settings.skipSeconds}s',
          onTap: () => _choose(
            'Skip button length',
            {
              for (final s in const [30, 60, 75, 85, 90, 120]) s: '$s seconds',
            },
            Settings.skipSeconds,
            (v) => Settings.skipSeconds = v,
          ),
        ),
        _Choice(
          title: 'Default speed',
          value: '${Settings.speed}×',
          onTap: () => _choose(
            'Default speed',
            {
              for (final s in const [.75, 1.0, 1.25, 1.5, 2.0]) s: '$s×',
            },
            Settings.speed,
            (v) => Settings.speed = v,
          ),
        ),
        _Choice(
          title: 'Default picture',
          value: pictureFits[Settings.videoFit]!,
          onTap: () => _choose(
            'Default picture',
            pictureFits,
            Settings.videoFit,
            (v) => Settings.videoFit = v,
          ),
        ),
      ]),
      _Group('Subtitles', [
        _Choice(
          title: 'Language',
          value: Settings.subtitleLanguage,
          onTap: () => _choose(
            'Subtitle language',
            {for (final l in subtitleLanguages) l: l},
            Settings.subtitleLanguage,
            (v) => Settings.subtitleLanguage = v,
          ),
        ),
        _Choice(
          title: 'Size',
          value:
              {
                18.0: 'Small',
                22.0: 'Medium',
                28.0: 'Large',
              }[Settings.subtitleSize] ??
              'Medium',
          onTap: () => _choose(
            'Subtitle size',
            {18.0: 'Small', 22.0: 'Medium', 28.0: 'Large'},
            Settings.subtitleSize,
            (v) => Settings.subtitleSize = v,
          ),
        ),
      ]),
      _Group('Storage', [
        if (Platform.isIOS)
          const ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text('Downloads stay in AniView'),
            subtitle: Text(
              'Keep the app open while downloading. Saved episodes are available offline.',
            ),
          ),
        _Choice(
          title: 'Download quality',
          subtitle: 'Lower quality takes less space',
          value: _qualities[Settings.downloadQuality] ?? 'Best',
          onTap: () => _choose(
            'Download quality',
            _qualities,
            Settings.downloadQuality,
            (v) => Settings.downloadQuality = v,
          ),
        ),
        if (isDesktop)
          ListenableBuilder(
            listenable: Downloads.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('Download folder'),
              subtitle: Text(Downloads.instance.folder),
              trailing: Settings.desktopDownloadFolder.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Back to the app’s own folder',
                      icon: const Icon(Icons.restore_rounded),
                      onPressed: () => _moveDownloads(null),
                    ),
              onTap: () async {
                final folder = await getDirectoryPath(
                  confirmButtonText: 'Keep downloads here',
                );
                if (folder != null) await _moveDownloads(folder);
              },
            ),
          ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('Save downloads to gallery'),
            subtitle: const Text(
              'Also copies each finished episode to the selected folder',
            ),
            value: Settings.saveToGallery,
            onChanged: (v) => setState(() => Settings.saveToGallery = v),
          ),
        if (Platform.isAndroid && Settings.saveToGallery)
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Download folder'),
            subtitle: Text(Settings.downloadFolderLabel),
            trailing: Settings.downloadFolder.isEmpty
                ? const Icon(Icons.chevron_right_rounded)
                : IconButton(
                    tooltip: 'Use app storage for new downloads',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () =>
                        setState(() => Settings.downloadFolder = ''),
                  ),
            onTap: () async {
              try {
                final folder = await AndroidApp.pickDownloadFolder();
                if (folder != null && mounted) {
                  setState(() => Settings.downloadFolder = folder);
                }
              } catch (e) {
                if (mounted) showError(this.context, e);
              }
            },
          ),
        ListenableBuilder(
          listenable: Downloads.instance,
          builder: (context, _) => DestructiveTile(
            icon: Icons.download_for_offline_outlined,
            title: 'Delete all downloads',
            subtitle: Text(
              '${formatBytes(Downloads.instance.totalBytes)} used on this device',
            ),
            onTap: Downloads.instance.items.isEmpty
                ? null
                : () async {
                    if (!await _confirm(
                      'Delete all downloads?',
                      'Every downloaded episode will be removed from this device.',
                      'Delete',
                    )) {
                      return;
                    }
                    await Downloads.instance.removeAll();
                    if (context.mounted) {
                      showSuccess(context, 'All downloads deleted');
                    }
                  },
          ),
        ),
        DestructiveTile(
          icon: Icons.history_rounded,
          title: 'Clear watch history',
          subtitle: const Text(
            'Removes continue-watching positions on this device',
          ),
          onTap: () async {
            if (!await _confirm(
              'Clear watch history?',
              'Saved positions will be removed.',
              'Clear',
            )) {
              return;
            }
            await WatchHistory.clear();
            if (context.mounted) {
              showSuccess(context, 'Watch history cleared');
            }
          },
        ),
        DestructiveTile(
          icon: Icons.link_off_rounded,
          title: 'Reset show matches',
          subtitle: const Text('Forget shows you picked manually on each site'),
          onTap: () async {
            await clearMatches();
            if (context.mounted) {
              showSuccess(context, 'Show matches reset');
            }
          },
        ),
        DestructiveTile(
          icon: Icons.verified_user_outlined,
          title: 'Clear site verifications',
          subtitle: const Text(
            'Use this if a site keeps failing after verifying',
          ),
          onTap: () async {
            await CookieManager.instance().deleteAllCookies();
            if (context.mounted) {
              showSuccess(context, 'Site verifications cleared');
            }
          },
        ),
      ]),
      _Group('About', [
        FutureBuilder(
          future: AndroidApp.version(),
          builder: (context, snap) => ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text(appName),
            subtitle: Text(
              snap.hasData
                  ? 'Version ${snap.data}${Platform.isIOS ? ' · Update through your sideloading app' : ' · ${isDesktop ? 'Click' : 'Tap'} to check for updates'}'
                  : 'Version',
            ),
            trailing: Platform.isIOS
                ? null
                : Icon(
                    isDesktop
                        ? Icons.refresh_rounded
                        : Icons.system_update_rounded,
                    size: 18,
                  ),
            onTap: Platform.isIOS ? null : () => checkForUpdate(context),
          ),
        ),
        if (Platform.isLinux)
          FutureBuilder(
            future: launcherInstalled(),
            builder: (_, snap) => ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: Text(
                snap.data == true
                    ? 'Update the app menu entry'
                    : 'Add AniView to the app menu',
              ),
              subtitle: const Text(
                'A launcher with its icon, which also lets the browser return you here after signing in',
              ),
              onTap: () async {
                await installLauncher();
                if (!mounted) return;
                showSuccess(this.context, 'AniView is in your app menu');
                setState(() {});
              },
            ),
          ),
        ListTile(
          leading: const Icon(Icons.new_releases_outlined),
          title: const Text('What’s new'),
          subtitle: const Text('Version $changelogVersion'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showChangelog(context),
        ),
        if (Analytics.available)
          SwitchListTile(
            title: const Text('Share anonymous usage stats'),
            subtitle: const Text(
              'Which screens and features get used. No account, search text or personal data',
            ),
            value: Settings.analytics,
            // Sent while analytics is on: before switching it off, after switching it on.
            onChanged: (v) {
              if (!v) Analytics.event('usage_stats', {'enabled': false});
              setState(() => Settings.analytics = v);
              if (v) Analytics.event('usage_stats', {'enabled': true});
            },
          ),
        for (final (icon, title, url) in const [
          (
            Icons.coffee_rounded,
            'Buy me a coffee',
            'https://www.buymeacoffee.com/kidfury',
          ),
          (Icons.discord, 'Join the Discord', 'https://discord.gg/TXkEgGK9cp'),
          (
            Icons.code_rounded,
            'GitHub',
            'https://github.com/ebrahimHakimuddin',
          ),
          (
            Icons.description_outlined,
            'Resume',
            'https://resume.ebrahim.co.tz',
          ),
        ])
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(url.replaceFirst('https://', '')),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => AndroidApp.open(url).ignore(),
          ),
      ]),
    ];
    if (isDesktop) return _desktop(sections);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        toolbarHeight: isTv ? 72 : 64,
        titleSpacing: side,
        titleTextStyle: Theme.of(context).textTheme.headlineMedium,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          0,
          // TV: a readable column rather than lines across the whole screen.
          isTv ? MediaQuery.sizeOf(context).width * .3 : 0,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: sections,
      ),
    );
  }
}

/// A titled group of settings, Android Settings style: the title in the accent colour, rows under it.
class _Group extends StatelessWidget {
  const _Group(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(side, 24, side, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: scheme.primary),
        ),
      ),
      ...children,
    ],
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.value,
    required this.onTap,
    this.subtitle,
  });

  final String title, value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text(subtitle == null ? value : '$value · $subtitle'),
    onTap: onTap,
  );
}

/// An account at the top of Settings: AniList or MyAnimeList, one signed in at a time.
class _Account extends StatelessWidget {
  const _Account({
    required this.provider,
    required this.other,
    required this.onSignIn,
    required this.onSignOut,
  });

  final ListProvider provider;

  /// The other account, when it's the one signed in: signing in here switches from it.
  final ListProvider? other;
  final VoidCallback onSignIn, onSignOut;

  bool get signedIn => provider.signedIn;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(side, 8, side, 0),
    child: Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: FutureBuilder(
        future: provider.viewer().catchError((Object _) => null),
        builder: (context, snap) {
          final avatar = snap.data?['avatar']?['large'] as String?;
          return ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: scheme.secondaryContainer,
              backgroundImage: avatar == null ? null : NetworkImage(avatar),
              child: avatar == null
                  ? Icon(
                      Icons.person_rounded,
                      color: scheme.onSecondaryContainer,
                    )
                  : null,
            ),
            title: Text(
              signedIn ? (snap.data?['name'] ?? provider.name) : provider.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(
              signedIn
                  ? 'Your list and progress are kept here'
                  : other != null
                  ? 'Switching signs you out of ${other!.name}'
                  : 'Sign in to track what you watch',
            ),
            trailing: signedIn
                ? OutlinedButton(
                    style: destructiveButton,
                    onPressed: onSignOut,
                    child: const Text('Sign out'),
                  )
                : other != null
                ? OutlinedButton(
                    onPressed: onSignIn,
                    child: const Text('Switch'),
                  )
                : FilledButton(
                    onPressed: onSignIn,
                    child: const Text('Sign in'),
                  ),
          );
        },
      ),
    ),
  );
}

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
            // Dragging needs touch; a remote moves rows with buttons.
            secondary: !isTv
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
