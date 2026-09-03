import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'downloads.dart';
import 'history.dart';
import 'sources.dart';
import 'states.dart';

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

  Future<void> _signIn() async {
    if (AniList.clientId.isEmpty) {
      showError(
        context,
        'This build has no AniList client id (--dart-define=ANILIST_CLIENT_ID)',
      );
      return;
    }
    try {
      await AniList.login(context);
      final me = await AniList.viewer();
      if (mounted && me != null) {
        showSuccess(context, 'Signed in as ${me['name']}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _signOut() async {
    await AniList.logout();
    if (!mounted) return;
    setState(() {});
    showSuccess(context, 'Signed out of AniList');
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = AniList.token != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _Group('AniList', [
            FutureBuilder(
              future: AniList.viewer(),
              builder: (context, snap) {
                final avatar = snap.data?['avatar']?['large'] as String?;
                return ListTile(
                  leading: avatar == null
                      ? const Icon(Icons.account_circle_rounded, size: 40)
                      : CircleAvatar(
                          radius: 20,
                          backgroundImage: NetworkImage(avatar),
                        ),
                  title: Text(
                    signedIn
                        ? (snap.data?['name'] ?? 'AniList')
                        : 'Not signed in',
                  ),
                  subtitle: Text(
                    signedIn
                        ? 'Your progress syncs to AniList'
                        : 'Sign in to track what you watch',
                  ),
                  trailing: signedIn
                      ? TextButton(
                          onPressed: _signOut,
                          child: const Text('Sign out'),
                        )
                      : FilledButton(
                          onPressed: _signIn,
                          child: const Text('Sign in'),
                        ),
                );
              },
            ),
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
                      s.name: s.name,
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
