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
import 'survey.dart';
import 'subtitle_appearance.dart';
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
import 'upscale.dart';

part 'settings/update.dart';
part 'settings/screen.dart';
part 'settings/home_sections.dart';

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
  latestEpisodes(
    'Latest episodes',
    'Recently aired anime across the catalog, not just your list',
  ),
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

  static bool get fallbackToSub => _prefs.getBool('fallback_to_sub') ?? false;
  static set fallbackToSub(bool v) => _prefs.setBool('fallback_to_sub', v);

  static bool get groupSeasons => _prefs.getBool('group_seasons') ?? false;
  static set groupSeasons(bool v) => _prefs.setBool('group_seasons', v);

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

  /// What a dub starts with: 'dubtitles' (captions for the dub when the stream has them, else the usual pick) or 'off'.
  static String get dubSubtitles =>
      _prefs.getString('dub_subtitles') ?? 'dubtitles';
  static set dubSubtitles(String v) => _prefs.setString('dub_subtitles', v);

  /// Anime4K upscaling in the player, on the platforms that play through mpv (see [usesMediaKit]); off by default.
  static Upscale get upscale => Upscale.parse(_prefs.getString('upscale'));
  static set upscale(Upscale v) => _prefs.setString('upscale', v.name);

  static SubtitleAppearance get subtitleAppearance {
    try {
      final saved = jsonDecode(_prefs.getString('subtitle_appearance') ?? '{}');
      return SubtitleAppearance.fromJson({
        'size': _prefs.getDouble('subtitle_size') ?? 22,
        if (saved is Map) ...saved,
      });
    } catch (_) {
      return const SubtitleAppearance();
    }
  }

  static set subtitleAppearance(SubtitleAppearance v) =>
      _prefs.setString('subtitle_appearance', jsonEncode(v.toJson()));
  static double get subtitleSize => subtitleAppearance.size;
  static set subtitleSize(double v) =>
      subtitleAppearance = subtitleAppearance.copyWith(size: v);

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
  static Future<void> setDesktopDownloadFolder(String v) async {
    if (!await _prefs.setString('desktop_download_folder', v)) {
      throw StateError('Could not save the download folder');
    }
  }

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

  static const _subscriptionSurveyKey = isBetaBuild
      ? 'subscription_survey_beta_v2'
      : 'subscription_survey_v1';
  static String? get subscriptionSurveyState =>
      _prefs.getString(_subscriptionSurveyKey);
  static Future<bool> setSubscriptionSurveyState(String state) =>
      _prefs.setString(_subscriptionSurveyKey, state);

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
