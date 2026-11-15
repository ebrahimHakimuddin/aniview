part of '../settings.dart';

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
