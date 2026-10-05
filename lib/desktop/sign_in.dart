import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../platform.dart';
import '../ui.dart';
import 'launcher.dart';

/// Signs in with the system browser: opens [url], and waits for the tracker (called [name]) to send the browser on to
/// an `aniview://` link, which the OS hands back to this app. Returns what [pick] reads from it (a token or code),
/// or null when it was cancelled or nothing came back in five minutes.
Future<String?> signInInBrowser(
  BuildContext context,
  String url, {
  required String name,
  required String? Function(Uri redirect) pick,
}) async {
  await _registerScheme();
  final token = Completer<String?>();
  var dialogOpen = true;
  final sub = AppLinks().uriLinkStream.listen((uri) {
    if (uri.scheme != 'aniview' || token.isCompleted) return;
    token.complete(pick(uri));
  });
  try {
    await AndroidApp.open(url);
    if (!context.mounted) return null;
    // However the dialog goes (Cancel, Esc), no answer is coming.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => _Waiting(
          name: name,
          onAgain: () => AndroidApp.open(url),
          onCancel: () {
            if (!token.isCompleted) token.complete(null);
          },
        ),
      ).then((_) {
        dialogOpen = false;
        if (!token.isCompleted) token.complete(null);
      }),
    );
    final value = await token.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => null,
    );
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    return value;
  } finally {
    await sub.cancel();
  }
}

/// Tells the desktop to open `aniview://` links with this app: its menu entry, which also registers the scheme, as a
/// Linux package would install (kept pointing at where the app is now); a hidden one when it isn't in the menu.
Future<void> _registerScheme() async {
  if (!Platform.isLinux) return;
  try {
    if (await launcherInstalled()) {
      await installLauncher();
      return;
    }
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final dir = Directory('$home/.local/share/applications');
    final file = File('${dir.path}/aniview-link.desktop');
    final entry =
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=AniView\n'
        'Exec="${Platform.resolvedExecutable}" %u\n'
        'MimeType=x-scheme-handler/aniview;\n'
        'NoDisplay=true\n';
    if (!await file.exists() || await file.readAsString() != entry) {
      await dir.create(recursive: true);
      await file.writeAsString(entry);
    }
    await Process.run('xdg-mime', [
      'default',
      'aniview-link.desktop',
      'x-scheme-handler/aniview',
    ]);
  } catch (_) {} // the browser then can't hand the link back; the dialog's Cancel still works
}

class _Waiting extends StatelessWidget {
  const _Waiting({
    required this.name,
    required this.onAgain,
    required this.onCancel,
  });

  final String name;
  final VoidCallback onAgain, onCancel;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Sign in with $name'),
    content: Row(
      children: [
        const SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Text(
            'Finish signing in in your browser. This window closes by itself once you approve.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: onAgain, child: const Text('Open the page again')),
      TextButton(onPressed: onCancel, child: const Text('Cancel')),
    ],
  );
}
