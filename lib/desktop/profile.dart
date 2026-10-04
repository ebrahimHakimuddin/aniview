import 'package:flutter/material.dart';

import '../home_feed.dart';
import '../library.dart' show StatsView;
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import 'widgets.dart';

/// Desktop profile: your AniList account and what you've watched, on a page of its own; signing out is here.
class DeskProfile extends StatelessWidget {
  const DeskProfile(
    this.feed, {
    super.key,
    required this.onRefresh,
    required this.onSignedOut,
  });

  final HomeFeed feed;
  final Future<void> Function() onRefresh;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.surface,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FutureBuilder(
                    future: feed.viewer,
                    builder: (context, snap) {
                      final me = snap.data;
                      final avatar = me?['avatar']?['large'] as String?;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(
                          deskMargin,
                          32,
                          deskMargin,
                          16,
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 40,
                              backgroundColor: scheme.surfaceContainerHigh,
                              foregroundImage: avatar == null
                                  ? null
                                  : NetworkImage(avatar),
                              child: Icon(
                                Icons.person_rounded,
                                size: 40,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    me?['name'] as String? ?? 'Your profile',
                                    style: text.headlineMedium,
                                  ),
                                  Text(
                                    'AniList',
                                    style: text.bodyMedium?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                await Tracker.signOut();
                                if (!context.mounted) return;
                                showSuccess(context, 'Signed out of AniList');
                                onSignedOut();
                              },
                              icon: const Icon(Icons.logout_rounded),
                              label: const Text('Sign out'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  if (Tracker.signedIn)
                    StatsView(feed.stats, onRetry: onRefresh)
                  else
                    const EmptyState(
                      compact: true,
                      icon: Icons.insights_rounded,
                      title: 'Your stats',
                      message: 'Sign in with AniList to see your time watched, your list and your activity.',
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
