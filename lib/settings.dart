import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'mal.dart';
import 'downloads.dart';
import 'history.dart';
import 'sources.dart';
import 'states.dart';

typedef _Service = ({
  String name,
  String define,
  bool usable,
  bool Function() signedIn,
  Future<void> Function(BuildContext) login,
  Future<void> Function() logout,
  Future<Map<String, dynamic>?> Function() viewer,
});

/// The trackers you can sign into. AniList leads; MAL covers for it when AniList can't be reached.
final List<_Service> _services = [
  (
    name: 'AniList',
    define: 'ANILIST_CLIENT_ID',
    usable: AniList.usable,
    signedIn: _aniListIn,
    login: AniList.login,
    logout: AniList.logout,
    viewer: AniList.viewer,
  ),
  (
    name: 'MyAnimeList',
    define: 'MAL_CLIENT_ID',
    usable: MAL.usable,
    signedIn: _malIn,
    login: MAL.login,
    logout: MAL.logout,
    viewer: MAL.viewer,
  ),
];

bool _aniListIn() => AniList.token != null;
bool _malIn() => MAL.token != null;

enum SkipMode { button, auto, off }

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

  static int get seekSeconds => _prefs.getInt('seek_seconds') ?? 10;
  static set seekSeconds(int v) => _prefs.setInt('seek_seconds', v);

  /// Length of the fixed skip button, for shows AniSkip has no times for.
  static int get skipSeconds => _prefs.getInt('skip_seconds') ?? 85;
  static set skipSeconds(int v) => _prefs.setInt('skip_seconds', v);

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
}

/// App version and opening links in the browser, answered by MainActivity.
const _app = MethodChannel('aniview/app');

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
    final current = await _app.invokeMethod<String>('version') ?? '';
    final res = await http
        .get(Uri.parse(_latestRelease))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw HttpException('${res.statusCode}');
    final release = jsonDecode(res.body) as Map;
    final latest = release['tag_name'] as String;
    final abi = await _app.invokeMethod<String>('abi');
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
          backgroundColor: const Color(0xFF1C1C26),
          showCloseIcon: true,
          content: Text(
            'AniView $version is available',
            style: const TextStyle(color: Colors.white),
          ),
          action: SnackBarAction(
            label: 'Update',
            onPressed: () async {
              if (apk == null) {
                return _app.invokeMethod('open', release['html_url']).ignore();
              }
              await _app.invokeMethod('download', {
                'url': apk['browser_download_url'],
                'title': 'AniView $version',
              });
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
  Future<void> _choose<T>(
    String title,
    Map<T, String> options,
    T current,
    void Function(T) apply,
  ) async {
    final primary = Theme.of(context).colorScheme.primary;
    final picked = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF14141C),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final MapEntry(:key, :value) in options.entries)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(value),
                  trailing: key == current
                      ? Icon(Icons.check_rounded, color: primary)
                      : null,
                  onTap: () => Navigator.pop(context, key),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _signIn(_Service service) async {
    if (!service.usable) {
      showError(
        context,
        'This build has no ${service.name} client id (--dart-define=${service.define})',
      );
      return;
    }
    try {
      await service.login(context);
      final me = await service.viewer();
      if (mounted && me != null) {
        showSuccess(context, 'Signed in as ${me['name']}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _signOut(_Service service) async {
    await service.logout();
    if (!mounted) return;
    setState(() {});
    showSuccess(context, 'Signed out of ${service.name}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _Group('Tracking', [
            for (final service in _services)
              _AccountTile(
                service,
                onSignIn: () => _signIn(service),
                onSignOut: () => _signOut(service),
              ),
            SwitchListTile(
              title: const Text('Update progress automatically'),
              subtitle: const Text(
                'Marks the episode watched on every signed-in service',
              ),
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
              future: sites,
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
            _Choice(
              title: 'Double-tap to seek',
              value: '${Settings.seekSeconds}s',
              onTap: () => _choose(
                'Double-tap to seek',
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
              future: _app.invokeMethod<String>('version'),
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
                onTap: () => _app.invokeMethod('open', url).ignore(),
              ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 28),
            child: Text(
              'AniView · Sites ranked by everythingmoe · Tracking by AniList\nSkip times by AniSkip · Episode art by ani.zip',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white38,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Material(
          color: const Color(0xFF14141C),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
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
    subtitle: subtitle == null ? null : Text(subtitle!),
    onTap: onTap,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: const TextStyle(color: Colors.white60)),
        const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      ],
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile(
    this.service, {
    required this.onSignIn,
    required this.onSignOut,
  });

  final _Service service;
  final VoidCallback onSignIn, onSignOut;

  @override
  Widget build(BuildContext context) {
    final signedIn = service.signedIn();
    return FutureBuilder(
      future: signedIn ? service.viewer() : null,
      builder: (context, snap) {
        final avatar = snap.data?['avatar']?['large'] as String?;
        return ListTile(
          leading: avatar == null
              ? const Icon(Icons.account_circle_rounded, size: 40)
              : CircleAvatar(radius: 20, backgroundImage: NetworkImage(avatar)),
          title: Text(
            signedIn ? '${snap.data?['name'] ?? service.name}' : service.name,
          ),
          subtitle: Text(
            signedIn
                ? 'Your progress syncs to ${service.name}'
                : 'Not signed in',
          ),
          trailing: signedIn
              ? TextButton(onPressed: onSignOut, child: const Text('Sign out'))
              : FilledButton(onPressed: onSignIn, child: const Text('Sign in')),
        );
      },
    );
  }
}
