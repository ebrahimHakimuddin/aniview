import 'dart:convert';
import 'dart:io';

import 'package:aniview/extensions.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

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
  ExtensionHost.current = const ChannelExtensionHost(android: true);
  addTearDown(() {
    ExtensionHost.current = const ChannelExtensionHost();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
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
            'audios': [
              {'url': 'https://cdn.test/ja.m4a', 'lang': 'Japanese'},
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
      expect(dub.single.audios.single.url, 'https://cdn.test/ja.m4a');
      expect(dub.single.audios.single.label, 'Japanese');
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

  group('the extension host', () {
    tearDown(() => ExtensionHost.current = const ChannelExtensionHost());

    test('lists every source once, for the sources and the installed extensions alike', () async {
      _answer(
        (call) => [
          {
            'id': '1',
            'pkg': 'pkg.a',
            'version': '16.1',
            'name': 'A',
            'lang': 'en',
            'baseUrl': 'https://a.test',
          },
          {
            'id': '2',
            'pkg': 'pkg.a',
            'version': '16.1',
            'name': 'A2',
            'lang': 'fr',
            'baseUrl': null,
          },
          // Installed before AniView hid it: no site, but still listed to uninstall.
          {
            'id': '3',
            'pkg': 'eu.kanade.tachiyomi.animeextension.en.reanime',
            'version': '16.1',
            'name': 'Re:Anime',
            'lang': 'en',
            'baseUrl': 'https://reanime.to',
          },
        ],
      );
      expect((await ExtensionSource.installed()).map((s) => s.name), [
        'A',
        'A2 (FR)',
      ]);
      final installed = await Extensions.installed();
      expect(installed['pkg.a']?.version, '16.1');
      expect(installed['pkg.a']?.sources, ['A', 'A2']);
      expect(
        installed,
        contains('eu.kanade.tachiyomi.animeextension.en.reanime'),
      );
    });

    test('lists nothing off Android', () async {
      _answer((_) => fail('the channel was asked'));
      expect(await const ChannelExtensionHost().sources(), isEmpty);
      expect(await const ChannelExtensionHost().search('1', 'x'), isEmpty);
    });

    test(
      'episodes are renumbered by position when the host states no numbers',
      () async {
        final host = FakeHost()
          ..episodeList = [
            for (final n in ['c', 'b', 'a']) Episode(-1, title: n, ref: n),
          ];
        final episodes = await ExtensionSource(
          '1',
          'Test',
          'https://t.test',
          host: host,
        ).episodesOf('/show');
        expect(
          [for (final e in episodes) (e.number, e.title)],
          [(1, 'a'), (2, 'b'), (3, 'c')],
        );
      },
    );

    test('streams follow the audio asked for, and all of them when only the other exists', () async {
      final host = FakeHost()
        ..videoList = [
          VideoStream('Server - Dub', 'https://cdn.test/dub.m3u8', {}),
          VideoStream('Server - Sub', 'https://cdn.test/sub.m3u8', {}),
        ];
      final source = ExtensionSource('1', 'T', 'https://t.test', host: host);
      final episode = Episode(1, ref: {});
      expect(
        (await source.streams(media, episode, dub: true)).map((s) => s.url),
        ['https://cdn.test/dub.m3u8'],
      );
      host.videoList = [host.videoList.last];
      expect(await source.streams(media, episode, dub: true), hasLength(1));
    });

    test(
      'installing and uninstalling make the site list load afresh',
      () async {
        final dir = await Directory.systemTemp.createTemp();
        addTearDown(() => dir.delete(recursive: true));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => dir.path,
            );
        var loads = 0;
        Sites.load = () async {
          loads++;
          return [];
        };
        addTearDown(() {
          Sites.load = topSources;
          Sites.reload();
        });
        final host = FakeHost();
        ExtensionHost.current = host;
        Sites.reload();
        await Sites.all();
        await Sites.all();
        expect(loads, 1);

        final info = ExtensionInfo(
          const ExtensionRepo('https://repo.test/index.min.json', 'R', 'AB12'),
          {
            'pkg': 'pkg.a',
            'apk': 'a.apk',
            'name': 'A',
            'lang': 'en',
            'version': '16.1',
          },
        );
        await http.runWithClient(
          () => Extensions.install(info),
          () => MockClient((_) async => http.Response('apk', 200)),
        );
        expect(host.installed, ['a.apk:AB12']);
        await Sites.all();
        expect(loads, 2);

        await Extensions.uninstall('pkg.a');
        expect(host.removed, ['pkg.a']);
        await Sites.all();
        expect(loads, 3);
      },
    );
  });

  group('the site list', () {
    final builtIn = [AniPm('ani.pm', 'https://ani.test')];
    final host = FakeHost();
    setUp(() {
      Sites.load = () async => builtIn;
      ExtensionHost.current = host;
      host.sourceError = null;
      host.sourceList = [
        (
          id: '9',
          pkg: 'p',
          version: '16.1',
          name: 'Ext',
          lang: 'en',
          baseUrl: 'https://ext.test',
        ),
      ];
      Sites.reload();
    });
    tearDown(() {
      ExtensionHost.current = const ChannelExtensionHost();
      Sites.extensionsPatience = const Duration(seconds: 15);
      Sites.reload();
    });

    test('has the installed extensions after the built-in sites', () async {
      expect((await Sites.all()).map((s) => s.name), ['ani.pm', 'Ext']);
    });

    test('keeps the built-in sites when the extension host fails', () async {
      host.sourceError = PlatformException(code: 'extension');
      expect((await Sites.all()).map((s) => s.name), ['ani.pm']);
    });

    test('keeps the built-in sites when the extension host stalls', () async {
      Sites.extensionsPatience = const Duration(milliseconds: 50);
      host.sourcesStall = true;
      addTearDown(() => host.sourcesStall = false);
      expect((await Sites.all()).map((s) => s.name), ['ani.pm']);
    });
  });
}
