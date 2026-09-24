import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'downloads.dart';
import 'history.dart';
import 'notifications.dart';
import 'sources.dart';
import 'pairing.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';
import 'platform.dart';

enum SkipMode { button, auto, off }

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
  season('This season', 'Popular shows this season'),
  trending('Trending now', 'Trending on AniList');

  const HomeSection(this.label, this.description);
  final String label, description;

  /// On until the user changes the sections; the rest start off.
  bool get byDefault =>
      const {featured, airing, season, trending}.contains(this);
}

/// User preferences; read synchronously after [load] runs at startup.
class Settings {
  static late SharedPreferences _prefs;

  static Future<void> load() async =>
      _prefs = await SharedPreferences.getInstance();

  static bool get preferDub => _prefs.getBool('prefer_dub') ?? false;
  static set preferDub(bool v) => _prefs.setBool('prefer_dub', v);

  /// Site name to select first; empty means the highest ranked site.
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
  static bool get directVideo => _prefs.getBool('direct_video') ?? false;
  static set directVideo(bool v) => _prefs.setBool('direct_video', v);

  static double get speed => _prefs.getDouble('speed') ?? 1.0;
  static set speed(double v) => _prefs.setDouble('speed', v);

  /// Subtitle track to pick by label prefix ("English", "Spanish", …); "Off" disables subtitles.
  static String get subtitleLanguage =>
      _prefs.getString('subtitle_language') ?? 'English';
  static set subtitleLanguage(String v) =>
      _prefs.setString('subtitle_language', v);

  static double get subtitleSize => _prefs.getDouble('subtitle_size') ?? 22;
  static set subtitleSize(double v) => _prefs.setDouble('subtitle_size', v);

  static bool get syncAniList => _prefs.getBool('sync_anilist') ?? true;
  static set syncAniList(bool v) => _prefs.setBool('sync_anilist', v);

  static int get watchedPercent => _prefs.getInt('watched_percent') ?? 85;
  static set watchedPercent(int v) => _prefs.setInt('watched_percent', v);

  /// Ecchi shows out of browse and search (adult ones never show); on by default on a shared TV.
  static bool get hideNsfw => _prefs.getBool('hide_nsfw') ?? isTv;
  static set hideNsfw(bool v) => _prefs.setBool('hide_nsfw', v);

  static bool get newestFirst => _prefs.getBool('newest_first') ?? true;
  static set newestFirst(bool v) => _prefs.setBool('newest_first', v);

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

const _latestRelease =
    'https://api.github.com/repos/ebrahimHakimuddin/aniview/releases/latest';

/// Whether release tag [latest] ("v1.5.2") is a newer version than [current] ("1.5.1").
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) => [
    for (final p in v.replaceFirst('v', '').split('+').first.split('.'))
      int.tryParse(p) ?? 0,
  ];
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// The release asset built for [abi] ("arm64-v8a"), or null when there isn't one.
Map? updateApk(List assets, String? abi) => assets
    .cast<Map>()
    .where((a) => a['name'] == 'app-$abi-release.apk')
    .firstOrNull;

/// Offers the latest GitHub release when it is newer than this build.
/// [quiet] (the check on launch) stays silent when up to date or offline.
Future<void> checkForUpdate(BuildContext context, {bool quiet = false}) async {
  try {
    final current = await AndroidApp.version() ?? '';
    final res = await http
        .get(Uri.parse(_latestRelease))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw HttpException('${res.statusCode}');
    final release = jsonDecode(res.body) as Map;
    final latest = release['tag_name'] as String;
    final abi = await AndroidApp.abi();
    final apk = updateApk(release['assets'] as List? ?? const [], abi);
    final version = latest.replaceFirst('v', '');
    if (!context.mounted) return;
    if (!isNewerVersion(latest, current)) {
      if (!quiet) showSuccess(context, 'You have the latest version');
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          showCloseIcon: true,
          content: Text('AniView $version is available'),
          action: SnackBarAction(
            label: 'Update',
            onPressed: () async {
              if (apk == null) {
                return AndroidApp.open(release['html_url']).ignore();
              }
              await AndroidApp.downloadApk(
                apk['browser_download_url'],
                title: 'AniView $version',
              );
              if (context.mounted) {
                showSuccess(
                  context,
                  'Downloading update · tap the notification to install',
                );
              }
            },
          ),
        ),
      );
  } catch (e) {
    if (!quiet && context.mounted) showError(context, e);
  }
}

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

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _signIn() async {
    try {
      final name = await Tracker.signIn(context);
      if (mounted && name != null) showSuccess(context, 'Signed in as $name');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _signOut() async {
    await Tracker.signOut();
    if (!mounted) return;
    setState(() {});
    showSuccess(context, 'Signed out of AniList');
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = Tracker.signedIn;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        toolbarHeight: isTv ? 72 : null,
        titleSpacing: side,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          0,
          // TV: a readable column rather than lines across the whole screen.
          isTv ? MediaQuery.sizeOf(context).width * .3 : 0,
          32,
        ),
        children: [
          _Account(signedIn: signedIn, onSignIn: _signIn, onSignOut: _signOut),
          _Group('Tracking', [
            SwitchListTile(
              title: const Text('Update progress automatically'),
              subtitle: const Text('Marks the episode watched on AniList'),
              value: Settings.syncAniList,
              onChanged: (v) => setState(() => Settings.syncAniList = v),
            ),
            _Choice(
              title: 'Count as watched at',
              value: '${Settings.watchedPercent}%',
              onTap: () => _choose(
                'Count as watched at',
                {
                  for (final p in const [50, 60, 70, 75, 80, 85, 90, 95])
                    p: '$p%',
                },
                Settings.watchedPercent,
                (v) => Settings.watchedPercent = v,
              ),
            ),
          ]),
          _Group('Home screen', [
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
              subtitle: const Text(
                'Keeps ecchi titles out of browse and search',
              ),
              value: Settings.hideNsfw,
              onChanged: (v) => setState(() => Settings.hideNsfw = v),
            ),
          ]),
          _Group('Remote', [
            ListTile(
              leading: const Icon(Icons.settings_remote_rounded),
              title: Text(isTv ? 'Phone remote' : 'TV remote'),
              subtitle: Text(
                isTv ? 'Control AniView on this TV from your phone' : 'Control AniView on your TV, and sign it in, from this phone',
              ),
              onTap: () async {
                await Navigator.push(
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
            _Choice(
              title: 'Preferred audio',
              value: Settings.preferDub ? 'Dub' : 'Sub',
              onTap: () => _choose(
                'Preferred audio',
                const {
                  false: 'Sub (Japanese audio)',
                  true: 'Dub (English audio)',
                },
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
                    for (final s in snap.data ?? const <Source>[])
                      s.name: s.label,
                  },
                  Settings.preferredSource,
                  (v) => Settings.preferredSource = v,
                ),
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
            SwitchListTile(
              title: const Text('Use an external player'),
              subtitle: const Text(
                'Play episodes in MX Player, VLC or another installed app',
              ),
              value: Settings.externalPlayer,
              onChanged: (v) => setState(() => Settings.externalPlayer = v),
            ),
            SwitchListTile(
              title: const Text('Direct video output'),
              subtitle: const Text(
                'Smoother playback on TVs and slower phones. Turn off if the picture stays black',
              ),
              value: Settings.directVideo,
              onChanged: (v) => setState(() => Settings.directVideo = v),
            ),
            if (!isTv)
              SwitchListTile(
                title: const Text('Swipe gestures'),
                subtitle: const Text(
                  'Swipe to seek, brightness on the left, volume on the right',
                ),
                value: Settings.swipeGestures,
                onChanged: (v) => setState(() => Settings.swipeGestures = v),
              ),
            _Choice(
              title: isTv ? 'Left / right seeks' : 'Double-tap to seek',
              value: '${Settings.seekSeconds}s',
              onTap: () => _choose(
                isTv ? 'Left / right seeks' : 'Double-tap to seek',
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
                  for (final s in const [30, 60, 75, 85, 90, 120])
                    s: '$s seconds',
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
            SwitchListTile(
              title: const Text('Save downloads to gallery'),
              subtitle: const Text(
                'Also copies each finished episode to Movies/AniView',
              ),
              value: Settings.saveToGallery,
              onChanged: (v) => setState(() => Settings.saveToGallery = v),
            ),
            ListenableBuilder(
              listenable: Downloads.instance,
              builder: (context, _) => ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Delete all downloads'),
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
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Clear watch history'),
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
            ListTile(
              leading: const Icon(Icons.link_off_rounded),
              title: const Text('Reset show matches'),
              subtitle: const Text(
                'Forget shows you picked manually on each site',
              ),
              onTap: () async {
                await clearMatches();
                if (context.mounted) showSuccess(context, 'Show matches reset');
              },
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Clear site verifications'),
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
                title: const Text('AniView'),
                subtitle: Text(
                  snap.hasData
                      ? 'Version ${snap.data} · Tap to check for updates'
                      : 'Version',
                ),
                trailing: const Icon(Icons.system_update_rounded, size: 18),
                onTap: () => checkForUpdate(context),
              ),
            ),
            if (Analytics.available)
              SwitchListTile(
                title: const Text('Share anonymous usage stats'),
                subtitle: const Text(
                  'Which screens and features get used. No account, search text or personal data',
                ),
                value: Settings.analytics,
                onChanged: (v) => setState(() => Settings.analytics = v),
              ),
            for (final (icon, title, url) in const [
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
        ],
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

/// The AniList account at the top of Settings.
class _Account extends StatelessWidget {
  const _Account({
    required this.signedIn,
    required this.onSignIn,
    required this.onSignOut,
  });

  final bool signedIn;
  final VoidCallback onSignIn, onSignOut;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(side, 8, side, 0),
    child: Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: FutureBuilder(
        future: Tracker.viewer(),
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
              signedIn ? (snap.data?['name'] ?? 'AniList') : 'Not signed in',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(
              signedIn
                  ? 'Your progress syncs to AniList'
                  : 'Sign in with AniList to track what you watch',
            ),
            trailing: signedIn
                ? TextButton(
                    onPressed: onSignOut,
                    child: const Text('Sign out'),
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

  @override
  Widget build(BuildContext context) => Scaffold(
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
      padding: const EdgeInsets.only(bottom: 32),
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
              borderRadius: BorderRadius.circular(16),
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
