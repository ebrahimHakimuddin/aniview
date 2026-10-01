import 'package:flutter/material.dart';

import 'platform.dart';
import 'settings.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

const changelogVersion = '2.2.1';

const changelogHighlights = [
  'Updates now download inside the app, with their progress showing.',
  'Android’s install prompt appears as soon as the download finishes, with no notification to find.',
  'Updating works on TV too: the offer appears as a dialog you can reach with the remote.',
  'From Android 12, later updates install without asking again.',
];

const coffeeUrl = 'https://www.buymeacoffee.com/kidfury';
const discordUrl = 'https://discord.gg/TXkEgGK9cp';

Widget _highlight(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.check_circle_outline_rounded, color: scheme.primary),
      const SizedBox(width: 12),
      Expanded(child: Text(text)),
    ],
  ),
);

/// The overview of this version, from Settings → About.
Future<void> showChangelog(BuildContext context) => showSheet<void>(
  context,
  (sheet) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sheetTitle(sheet, 'What’s new in $changelogVersion'),
          for (final highlight in changelogHighlights)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _highlight(highlight),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  ),
);

/// Whether to show the overview now: once per version, so on the first launch after an update (or a fresh install),
/// and not again once it's been dismissed.
bool shouldShowWhatsNew({required String? seen, required String current}) =>
    seen != current;

/// On the first launch of a version, the overview of what changed, with the two ways to support or join AniView pinned
/// under it. It's shown once: dismissing it (by any means) notes the version, and it doesn't come back.
Future<void> maybeShowWhatsNew(BuildContext context) async {
  if (!shouldShowWhatsNew(
    seen: Settings.changelogSeen,
    current: changelogVersion,
  )) {
    return;
  }
  await showDialog<void>(context: context, builder: (_) => const _WhatsNew());
  Settings.changelogSeen = changelogVersion;
}

class _WhatsNew extends StatelessWidget {
  const _WhatsNew();

  Future<void> _open(BuildContext context, String url) async {
    try {
      await AndroidApp.open(url);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PanelDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('What’s new in $changelogVersion', style: text.titleLarge),
              const SizedBox(height: 16),
              // The overview scrolls; the buttons under it stay put.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final h in changelogHighlights) _highlight(h),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // A TV has no browser to open them in.
              if (!isTv) ...[
                OutlinedButton.icon(
                  onPressed: () => _open(context, coffeeUrl),
                  icon: const Icon(Icons.local_cafe_rounded),
                  label: const Text('Buy me a coffee'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _open(context, discordUrl),
                  icon: const Icon(Icons.forum_rounded),
                  label: const Text('Join Discord'),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton(
                autofocus: isTv,
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
