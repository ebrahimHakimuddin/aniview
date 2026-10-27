import 'package:flutter/material.dart';

import 'anilist.dart';
import 'latest_episodes.dart';
import 'settings.dart';
import 'ui.dart';

class LatestEpisodesSection extends StatefulWidget {
  const LatestEpisodesSection({super.key, this.autofocus = false, this.onBack});
  final bool autofocus;
  final VoidCallback? onBack;

  @override
  State<LatestEpisodesSection> createState() => _LatestEpisodesSectionState();
}

class _LatestEpisodesSectionState extends State<LatestEpisodesSection> {
  late final feed = LatestEpisodes(
    fetch: (page, before) => AniList.latestEpisodes(page: page, before: before),
  )..more();

  @override
  void dispose() {
    feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: feed,
    builder: (context, _) {
      final items = feed.items
          .where(
            (item) =>
                !Settings.hideNsfw ||
                !(item['media']['genres'] as List? ?? []).contains('Ecchi'),
          )
          .toList();
      if (items.isEmpty && feed.loading) {
        return const RowSkeleton(title: 'Latest episodes');
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaRow(
            'Latest episodes',
            [for (final item in items) item['media']],
            autofocus: widget.autofocus,
            onBack: widget.onBack,
            subtitles: [
              for (final item in items)
                'EP ${item['episode']} · Aired ${_date(item['airingAt'] as int)}',
            ],
          ),
          if (items.isEmpty && !feed.loading && feed.error == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No recent episodes found.'),
            ),
          if (feed.loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          else if (feed.hasMore || feed.error != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: TextButton.icon(
                onPressed: feed.more,
                icon: Icon(
                  feed.error != null ? Icons.refresh : Icons.expand_more,
                ),
                label: Text(
                  feed.error != null
                      ? 'Couldn’t load episodes · Retry'
                      : 'Load older episodes',
                ),
              ),
            ),
        ],
      );
    },
  );

  String _date(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${date.day}/${date.month}';
  }
}
