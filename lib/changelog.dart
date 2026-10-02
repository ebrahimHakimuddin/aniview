import 'package:flutter/material.dart';

import 'platform.dart';
import 'settings.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

const changelogVersion = '2.4.0';

/// One change worth telling the person about: a short [title] and a sentence of [body].
typedef ChangelogEntry = ({IconData icon, String title, String body});

const changelogHighlights = <ChangelogEntry>[
  (
    icon: Icons.contrast_rounded,
    title: 'Follows your phone’s light and dark',
    body: 'A switch in Settings → Appearance uses your theme’s light or dark version to match your phone.',
  ),
  (
    icon: Icons.swap_horiz_rounded,
    title: 'Try another site',
    body: 'When a site has nothing for an episode, the player offers another one so you can keep watching.',
  ),
  (
    icon: Icons.arrow_back_rounded,
    title: 'Smoother going back',
    body: 'Home waits for the back animation to end before it reloads, and rows you’ve scrolled past stay built.',
  ),
  (
    icon: Icons.animation_rounded,
    title: 'Calmer motion',
    body: 'With animations turned off in Android, loading placeholders and the 2× chevrons hold still. Springy overshoots are gone.',
  ),
  (
    icon: Icons.insights_rounded,
    title: 'Steadier lists and stats',
    body: 'Me shows your stats when AniList leaves its breakdown empty, completing a show counts every episode, and signing out clears saves still waiting.',
  ),
  (
    icon: Icons.download_for_offline_rounded,
    title: 'Download folder',
    body: 'The folder you pick applies only while Save downloads to gallery is on. Otherwise episodes stay in the app’s storage.',
  ),
];

const coffeeUrl = 'https://www.buymeacoffee.com/kidfury';
const discordUrl = 'https://discord.gg/TXkEgGK9cp';

/// The overview of this version in a bottom sheet (a panel on TV), from Settings → About.
Future<void> showChangelog(BuildContext context) =>
    showSheet<void>(context, (_) => const _WhatsNew(), scrollControlled: true);

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
  await showChangelog(context);
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

  Widget _entry(BuildContext context, ChangelogEntry entry) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(radiusMedium),
            ),
            child: Icon(entry.icon, color: scheme.primary, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.body,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sheetTitle(
          context,
          'What’s new in $changelogVersion',
          subtitle: 'The latest changes to AniView',
        ),
        // The overview scrolls; the buttons under it stay put.
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in changelogHighlights) _entry(context, entry),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A TV has no browser to open them in.
              if (!isTv) ...[
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _open(context, coffeeUrl),
                      icon: const Icon(Icons.local_cafe_rounded),
                      label: const Text('Buy me a coffee'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _open(context, discordUrl),
                      icon: const Icon(Icons.forum_rounded),
                      label: const Text('Join Discord'),
                    ),
                  ],
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
      ],
    ),
  );
}
