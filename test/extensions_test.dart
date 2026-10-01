import 'dart:async';
import 'dart:convert';

import 'package:aniview/extensions.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('aniview/extensions');

/// Answers the extensions channel as Extensions.kt would; [calls] records what was asked.
void _answer(
  Object? Function(MethodCall call) reply, {
  List<MethodCall>? calls,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls?.add(call);
        return reply(call);
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

Map _episode(String name, num number) => {
  'url': '/watch/$name',
  'name': name,
  'number': number,
  'preview': null,
  'summary': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final media = {
    'id': 1,
    'title': {
      'romaji': 'Kusuriya no Hitorigoto',
      'english': 'The Apothecary Diaries',
    },
  };

  group('repos', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      httpClient = MockClient((request) async {
        final url = request.url.toString();
        if (url.endsWith('/repo.json')) {
          return http.Response(
            jsonEncode({
              'meta': {'name': 'Test repo', 'signingKeyFingerprint': 'AB12'},
            }),
            200,
          );
        }
        if (url.endsWith('/index.min.json')) {
          return http.Response(
            jsonEncode([
              for (final (pkg, version) in [
                ('eu.kanade.tachiyomi.animeextension.en.alpha', '14.5'),
                ('eu.kanade.tachiyomi.animeextension.en.beta', '16.2'),
                ('eu.kanade.tachiyomi.animeextension.en.future', '17.1'),
                ('eu.kanade.tachiyomi.animeextension.en.anikoto', '16.8'),
                ('eu.kanade.tachiyomi.animeextension.all.nyaatorrent', '14.4'),
              ])
                {
                  'name': 'Aniyomi: ${pkg.split('.').last}',
                  'pkg': pkg,
                  'apk': 'aniyomi-${pkg.split('.').last}.apk',
                  'lang': 'en',
                  'version': version,
                  'nsfw': 0,
                },
            ]),
            200,
          );
        }
        return http.Response('', 404);
      });
    });

    test('a repo is added by its folder or its index, named and keyed by repo.json', () async {
      final byFolder = await Extensions.addRepo('https://repo.test/anime/ ');
      expect(byFolder.index, 'https://repo.test/anime/index.min.json');
      expect(byFolder.name, 'Test repo');
      expect(byFolder.fingerprint, 'AB12');

      await Extensions.addRepo('https://repo.test/anime/index.min.json');
      expect(
        await Extensions.repos(),
        hasLength(1),
      ); // the same repo, not twice

      await Extensions.removeRepo(byFolder);
      expect(await Extensions.repos(), isEmpty);
    });

    test('a URL with no repo.json is refused, and not saved', () async {
      httpClient = MockClient((_) async => http.Response('', 404));
      await expectLater(
        Extensions.addRepo('https://nope.test'),
        throwsException,
      );
      expect(await Extensions.repos(), isEmpty);
    });

    test('lists what the app can run: lib 14 and 16, not the built-in sites or torrent ones', () async {
      final repo = await Extensions.addRepo('https://repo.test/anime');
      final offered = await Extensions.available([repo]);
      expect([for (final e in offered) e.name], ['alpha', 'beta']);
    });
  });

  group('extension sources', () {
    test('match accepts only a result titled as the show, whatever its case or punctuation', () async {
      _answer(
        (call) => switch (call.method) {
          'search' => [
            {
              'url': '/a',
              'title': 'Kusuriya no Hitorigoto 2',
              'thumbnail': null,
            },
            {
              'url': '/b',
              'title': 'the apothecary diaries!',
              'thumbnail': null,
            },
          ],
          _ => throw MissingPluginException(),
        },
      );
      expect(
        await ExtensionSource('1', 'Test', 'https://t.test').match(media),
        '/b',
      );
    });

    test('match gives up rather than pick a different show', () async {
      _answer(
        (call) => [
          {'url': '/a', 'title': 'Something else entirely', 'thumbnail': null},
        ],
      );
      expect(
        await ExtensionSource('1', 'Test', 'https://t.test').match(media),
        isNull,
      );
    });

    test(
      'episodes that state their numbers are sorted by them, oldest first',
      () async {
        _answer(
          (call) => [_episode('c', 3), _episode('a', 1), _episode('b', 2)],
        );
        final episodes = await ExtensionSource(
          '1',
          'Test',
          'https://t.test',
        ).episodesOf('/show');
        expect([for (final e in episodes) e.number], [1, 2, 3]);
      },
    );

    test(
      'episodes with no numbers get their position, counted from the oldest',
      () async {
        // Extensions list newest first, and leave the number at -1 when they don't know it.
        _answer(
          (call) => [
            _episode('newest', -1),
            _episode('middle', -1),
            _episode('oldest', -1),
          ],
        );
        final episodes = await ExtensionSource(
          '1',
          'Test',
          'https://t.test',
        ).episodesOf('/show');
        expect(
          [for (final e in episodes) (e.number, e.title)],
          [(1, 'oldest'), (2, 'middle'), (3, 'newest')],
        );
      },
    );

    test('streams carry their headers, subtitles and skip times, and follow the audio asked for', () async {
      _answer(
        (call) => [
          {
            'title': 'Server 1 - Dub 1080p',
            'url': 'https://cdn.test/dub.m3u8',
            'headers': {'Referer': 'https://t.test/'},
            'subtitles': [
              {'url': 'https://cdn.test/en.vtt', 'lang': 'English'},
            ],
            'timestamps': [
              {'start': 5.0, 'end': 95.5, 'name': 'Opening', 'type': 'Opening'},
              {
                'start': 1300.0,
                'end': 1390.0,
                'name': 'Ending',
                'type': 'Ending',
              },
              {'start': 0.0, 'end': 1.0, 'name': 'x', 'type': 'Other'},
            ],
          },
          {
            'title': 'Server 1 - Sub 1080p',
            'url': 'https://cdn.test/sub.m3u8',
            'headers': null,
            'subtitles': [],
            'timestamps': [],
          },
        ],
      );
      final source = ExtensionSource('1', 'Test', 'https://t.test');
      final episode = Episode(1, ref: {'url': '/watch/1', 'name': 'Episode 1'});

      final dub = await source.streams(media, episode, dub: true);
      expect(dub.map((s) => s.url), ['https://cdn.test/dub.m3u8']);
      expect(dub.single.headers, {'Referer': 'https://t.test/'});
      expect(dub.single.subtitles.single.label, 'English');
      expect(dub.single.skips, hasLength(2)); // "Other" isn't a skip
      expect(dub.single.skips.first.end, const Duration(milliseconds: 95500));

      final sub = await source.streams(media, episode, dub: false);
      expect(sub.map((s) => s.url), ['https://cdn.test/sub.m3u8']);
    });

    test('a site\'s Cloudflare check becomes the challenge the app already knows how to show', () async {
      _answer(
        (call) => throw PlatformException(
          code: 'cloudflare',
          message: 'Cloudflare verification required',
          details: 'https://t.test/',
        ),
      );
      await expectLater(
        ExtensionSource('1', 'Test', 'https://t.test').search('x'),
        throwsA(
          isA<CloudflareChallenge>().having(
            (c) => c.url,
            'url',
            'https://t.test/',
          ),
        ),
      );
    });

    test('other failures keep their message', () async {
      _answer(
        (call) => throw PlatformException(code: 'extension', message: 'boom'),
      );
      await expectLater(
        ExtensionSource('1', 'Test', 'https://t.test').search('x'),
        throwsA(
          isA<PlatformException>().having((e) => e.message, 'message', 'boom'),
        ),
      );
    });
  });

  group('the site list', () {
    final builtIn = [ReAnime('Re:Anime', 'https://re.test')];
    final extension = ExtensionSource('9', 'Ext', 'https://ext.test');
    setUp(() {
      Sites.load = () async => builtIn;
      Sites.reload();
    });
    tearDown(() {
      Sites.loadExtensions = ExtensionSource.installed;
      Sites.extensionsPatience = const Duration(seconds: 15);
      Sites.reload();
    });

    test('has the installed extensions after the built-in sites', () async {
      Sites.loadExtensions = () async => [extension];
      expect((await Sites.all()).map((s) => s.name), ['Re:Anime', 'Ext']);
    });

    test('keeps the built-in sites when the extension host fails', () async {
      Sites.loadExtensions = () async =>
          throw PlatformException(code: 'extension');
      expect((await Sites.all()).map((s) => s.name), ['Re:Anime']);
    });

    test('keeps the built-in sites when the extension host stalls', () async {
      Sites.extensionsPatience = const Duration(milliseconds: 50);
      Sites.loadExtensions = () => Completer<List<Source>>().future;
      expect((await Sites.all()).map((s) => s.name), ['Re:Anime']);
    });
  });
}
