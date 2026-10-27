import 'dart:async';

import 'package:aniview/latest_episodes.dart';
import 'package:aniview/anilist.dart';
import 'package:aniview/playback.dart';
import 'package:aniview/season_group.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/subtitle_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
  });

  test(
    'latest catalog page excludes adult entries and keeps its paging window',
    () async {
      final oldTransport = AniList.transport;
      addTearDown(() => AniList.transport = oldTransport);
      AniList.transport = (query, variables) async {
        expect(query, contains('sort:TIME_DESC'));
        expect(variables, {'page': 2, 'before': 900000, 'after': 295200});
        return {
          'Page': {
            'pageInfo': {'hasNextPage': true},
            'airingSchedules': [
              {
                'media': {'id': 1, 'isAdult': true},
              },
              {
                'media': {'id': 2, 'isAdult': false},
              },
              {'media': null},
            ],
          },
        };
      };
      final (items, more) = await AniList.latestEpisodes(
        page: 2,
        before: 900000,
      );
      expect(items.map((item) => item['media']['id']), [2]);
      expect(more, isTrue);
    },
  );

  test(
    'broader features and dub fallback default off and persist when enabled',
    () async {
      expect(Settings.fallbackToSub, isFalse);
      expect(Settings.groupSeasons, isFalse);
      expect(
        Settings.homeSections,
        contains((HomeSection.latestEpisodes, false)),
      );
      Settings.fallbackToSub = true;
      Settings.groupSeasons = true;
      Settings.homeSections = [(HomeSection.latestEpisodes, true)];
      await Settings.load();
      expect(Settings.fallbackToSub, isTrue);
      expect(Settings.groupSeasons, isTrue);
      expect(
        Settings.homeSections,
        contains((HomeSection.latestEpisodes, true)),
      );
      Settings.fallbackToSub = false;
      Settings.groupSeasons = false;
      await Settings.load();
      expect(Settings.fallbackToSub, isFalse);
      expect(Settings.groupSeasons, isFalse);
    },
  );

  test(
    'subtitle appearance migrates size and persists the rendered options',
    () async {
      SharedPreferences.setMockInitialValues({'subtitle_size': 28.0});
      await Settings.load();
      expect(Settings.subtitleAppearance.size, 28);
      Settings.subtitleAppearance = Settings.subtitleAppearance.copyWith(
        color: 0xffffff00,
        background: .5,
        edge: 'outline',
        font: 'monospace',
        bold: true,
        bottom: 64,
      );
      await Settings.load();
      final appearance = Settings.subtitleAppearance;
      expect(appearance.bottom, 64);
      final style = appearance.style();
      expect(style.fontSize, 28);
      expect(style.color, const Color(0xffffff00));
      expect(style.fontFamily, 'monospace');
      expect(style.fontWeight, FontWeight.bold);
      expect(style.shadows, hasLength(4));
      expect(style.backgroundColor, Colors.black.withValues(alpha: .5));
      Settings.subtitleAppearance = const SubtitleAppearance();
      await Settings.load();
      expect(Settings.subtitleSize, 22);
      expect(Settings.subtitleAppearance.bottom, 32);
    },
  );

  const episodes = [Episode(1, ref: '1'), Episode(2, ref: '2')];
  const sub = VideoStream('Sub', '/sub.mp4', {});
  const dub = VideoStream('Dub', '/dub.mp4', {});
  for (final enabled in [false, true]) {
    test('dub fallback enabled=$enabled only tries Sub when allowed', () async {
      var subCalls = 0;
      final session = PlaybackSession(
        episodes,
        0,
        dub: true,
        allowSubFallback: enabled,
        downloaded: (_) => null,
        fetch: (e) async => e.number == 1 ? [] : [dub],
        fetchSub: (_) async {
          subCalls++;
          return [sub];
        },
      );
      if (enabled) {
        await session.open(0, at: Duration.zero);
        expect(session.streams.single, sub);
        expect(session.playingDub, isFalse);
        expect(session.fellBackToSub, isTrue);
        expect(session.dub, isTrue);
        expect(subCalls, 1);
        await session.open(1, at: Duration.zero);
        expect(session.streams.single, dub);
        expect(session.playingDub, isTrue);
        expect(session.fellBackToSub, isFalse);
        expect(subCalls, 1);
      } else {
        await expectLater(session.open(0, at: Duration.zero), throwsException);
        expect(subCalls, 0);
      }
    });
  }

  test('network failure is not treated as a missing dub', () async {
    var subCalls = 0;
    final session = PlaybackSession(
      episodes,
      0,
      dub: true,
      allowSubFallback: true,
      downloaded: (_) => null,
      fetch: (_) async => throw StateError('offline'),
      fetchSub: (_) async {
        subCalls++;
        return [sub];
      },
    );
    await expectLater(session.open(0, at: Duration.zero), throwsStateError);
    expect(subCalls, 0);
  });

  test('an obsolete sub fallback cannot overwrite the next episode', () async {
    final pending = Completer<List<VideoStream>>();
    final started = Completer<void>();
    final session = PlaybackSession(
      episodes,
      0,
      dub: true,
      allowSubFallback: true,
      downloaded: (_) => null,
      fetch: (e) async => e.number == 1 ? [] : [dub],
      fetchSub: (_) {
        started.complete();
        return pending.future;
      },
    );
    final old = session.open(0, at: Duration.zero);
    await started.future;
    await session.open(1, at: Duration.zero);
    pending.complete([sub]);
    expect(await old, isNull);
    expect(session.streams.single, dub);
    expect(session.playingDub, isTrue);
  });

  test(
    'download audio is recorded without attempting online fallback',
    () async {
      final session = PlaybackSession(
        episodes,
        0,
        dub: true,
        downloaded: (_) => sub,
        downloadedDub: (_) => false,
        fetch: (_) async => throw StateError('must not fetch'),
        allowSubFallback: true,
      );
      await session.open(0, at: Duration.zero);
      expect(session.fromDownload, isTrue);
      expect(session.playingDub, isFalse);
      expect(session.fellBackToSub, isFalse);
    },
  );

  test(
    'season grouping follows both directions and keeps IDs ordered once',
    () async {
      final calls = <int>[];
      final group = SeasonGroup(
        {'id': 2},
        relations: (m) async {
          final id = m['id'] as int;
          calls.add(id);
          return switch (id) {
            1 => [
              ('SEQUEL', {'id': 2}),
            ],
            2 => [
              ('PREQUEL', {'id': 1}),
              ('SEQUEL', {'id': 3}),
              ('SIDE_STORY', {'id': 99}),
            ],
            _ => [
              ('PREQUEL', {'id': 2}),
            ],
          };
        },
      );
      addTearDown(group.dispose);
      await group.loadMore();
      expect(group.items.map((m) => m['id']), [1, 2, 3]);
      expect(calls.toSet(), {1, 2, 3});
      expect(calls, hasLength(3));
      expect(group.hasMore, isFalse);
    },
  );

  test(
    'season errors retain discovered entries and retry the failing node',
    () async {
      var fail = true;
      final group = SeasonGroup(
        {'id': 1},
        relations: (m) async {
          if (m['id'] == 1) {
            return [
              ('SEQUEL', {'id': 2}),
            ];
          }
          if (fail) throw StateError('network');
          return [];
        },
      );
      addTearDown(group.dispose);
      await group.loadMore();
      expect(group.error, isNotNull);
      expect(group.items, hasLength(2));
      fail = false;
      await group.loadMore();
      expect(group.error, isNull);
      expect(group.hasMore, isFalse);
    },
  );

  test(
    'long franchises load in bounded batches and cycles terminate',
    () async {
      final group = SeasonGroup(
        {'id': 1},
        relations: (m) async {
          final id = m['id'] as int;
          return [
            ('SEQUEL', {'id': id == 15 ? 1 : id + 1}),
          ];
        },
      );
      addTearDown(group.dispose);
      await group.loadMore();
      expect(group.hasMore, isTrue);
      await group.loadMore();
      expect(group.items, hasLength(15));
      expect(group.items.map((m) => m['id']).toSet(), hasLength(15));
      expect(group.hasMore, isFalse);
    },
  );

  test('latest episodes pages retain results, retry same page and deduplicate shows', () async {
    final calls = <int>[];
    var fail = true;
    final feed = LatestEpisodes(
      before: 100,
      fetch: (page, before) async {
        expect(before, 100);
        calls.add(page);
        if (page == 1) {
          return (
            [
              {
                'media': {'id': 1},
                'episode': 2,
              },
            ],
            true,
          );
        }
        if (fail) throw StateError('network');
        return (
          [
            {
              'media': {'id': 1},
              'episode': 1,
            },
            {
              'media': {'id': 2},
              'episode': 1,
            },
          ],
          false,
        );
      },
    );
    addTearDown(feed.dispose);
    await feed.more();
    await feed.more();
    expect(feed.error, isNotNull);
    expect(feed.items, hasLength(1));
    fail = false;
    await feed.more();
    expect(calls, [1, 2, 2]);
    expect(feed.items.map((m) => m['media']['id']), [1, 2]);
    expect(feed.items.first['episode'], 2);
    expect(feed.hasMore, isFalse);
  });
}
