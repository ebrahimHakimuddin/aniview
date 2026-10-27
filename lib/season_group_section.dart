import 'package:flutter/material.dart';

import 'season_group.dart';
import 'tracker.dart';
import 'ui.dart';

class SeasonGroupSection extends StatefulWidget {
  const SeasonGroupSection(this.media, {super.key});
  final Map media;

  @override
  State<SeasonGroupSection> createState() => _SeasonGroupSectionState();
}

class _SeasonGroupSectionState extends State<SeasonGroupSection> {
  late final group = SeasonGroup(widget.media, relations: Tracker.relations)
    ..loadMore();

  @override
  void dispose() {
    group.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: group,
    builder: (context, _) {
      final items = group.items;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaRow(
            'Seasons & related entries',
            items,
            subtitles: [
              for (final media in items)
                media['id'] == widget.media['id']
                    ? 'Current entry'
                    : [
                        media['format']?.toString().replaceAll('_', ' '),
                        media['seasonYear']?.toString(),
                      ].whereType<String>().join(' · '),
            ],
          ),
          if (group.loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          else if (group.error != null || group.hasMore)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: TextButton.icon(
                onPressed: group.loadMore,
                icon: Icon(
                  group.error != null ? Icons.refresh : Icons.expand_more,
                ),
                label: Text(
                  group.error != null
                      ? 'Couldn’t load all seasons · Retry'
                      : 'Load more seasons',
                ),
              ),
            ),
        ],
      );
    },
  );
}
