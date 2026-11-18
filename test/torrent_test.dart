import 'dart:convert';
import 'dart:io';

import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/torrent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

String rss(List<(String, String, int)> items) =>
    '<rss><channel>${[for (final (title, hash, seeders) in items) '''
<item>
  <title>${title.replaceAll('&', '&amp;')}</title>
  <nyaa:seeders>$seeders</nyaa:seeders>
  <nyaa:infoHash>$hash</nyaa:infoHash>
  <nyaa:trusted>No</nyaa:trusted>
</item>'''].join()}</channel></rss>';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    RealDebrid.wait = Duration.zero;
  });

  test('release and file names say which episodes they hold', () {
    for (final (name, held) in [
      (
        '[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv',
        (season: null, from: 5, to: 5),
      ),
      (
        '[SubsPlease] Sousou no Frieren S2 - 03 (1080p) [ABCD1234].mkv',
        (season: 2, from: 3, to: 3),
      ),
      (
        '[SubsPlease] Sousou no Frieren (01-28) (1080p) [Batch]',
        (season: null, from: 1, to: 28),
      ),
      (
        "Frieren Beyond Journey's End - S01E01 (BD Remux 1080p AVC FLAC AAC) [Dual Audio] [PMR].mkv",
        (season: 1, from: 1, to: 1),
      ),
      (
        '[Erai-raws] Kaiju No. 8 - 05 [1080p][HEVC]',
        (season: null, from: 5, to: 5),
      ),
      ('Oshi no Ko 2nd Season - 03v2 (720p)', (season: 2, from: 3, to: 3)),
      (
        '[Judas] Mob Psycho 100 S3 [1080p][HEVC x265 10bit][Batch]',
        (season: 3, from: null, to: null),
      ),
      (
        '[AUTISM] Sousou no Frieren - S01v2 (BD Remux 1080p AVC FLAC/TrueHD/AAC 2.0/5.1) [Dual-Audio]',
        (season: 1, from: null, to: null),
      ),
      ('07 - The Title.mkv', (season: null, from: 7, to: 7)),
    ]) {
      expect(episodesIn(name), held, reason: name);
    }
  });

  test('a sequel matches its own numbering or the count from the start', () {
    bool ep3(String name) =>
        covers(episodesIn(name), 3, absolute: 31, season: 2);
    expect(ep3('[SubsPlease] Sousou no Frieren S2 - 03 (1080p)'), isTrue);
    expect(ep3('[SubsPlease] Sousou no Frieren - 31 (1080p)'), isTrue);
    expect(ep3('[SubsPlease] Sousou no Frieren - 03 (1080p)'), isFalse);
    expect(ep3('[SubsPlease] Sousou no Frieren (01-28) [Batch]'), isFalse);
    expect(ep3('Frieren S01E03.mkv'), isFalse);
  });

  test('the episode is picked out of a batch, or a torrent\'s only video', () {
    bool five(String name) {
      final held = episodesIn(name);
      return held.from == held.to && covers(held, 5);
    }

    expect(
      pickFile([
        'Frieren - 04 [1080p].mkv',
        'Frieren - 05 [1080p].mkv',
        'Frieren - 05 [1080p].ass',
      ], five),
      1,
    );
    expect(pickFile(['episode.mkv', 'info.nfo'], five), 0);
    expect(pickFile(['a.mkv', 'b.mkv'], five), isNull);
  });

  test('cached and trusted releases come first, dead ones are left out', () {
    const dead = Release('[A] Show - 01 (1080p)', 'dead');
    const seeded = Release('[B] Show - 01 (1080p)', 'seeded', seeders: 50);
    const small = Release('[C] Show - 01 (720p)', 'small', seeders: 500);
    const cached = Release('[D] Show - 01 (480p)', 'cached');
    expect(
      rankReleases(
        [dead, small, seeded, cached],
        {'cached'},
      ).map((r) => r.hash),
      ['cached', 'seeded', 'small'],
    );
  });

  test(
    'streams offer the releases holding the episode, resolved only when played',
    () async {
      Settings.realDebridKey = 'key';
      final added = <String>[];
      httpClient = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('addMagnet')) {
          added.add(
            request.bodyFields['magnet']!.split('btih:')[1].split('&')[0],
          );
          return http.Response('{"id":"T"}', 201);
        }
        if (path.contains('torrents/info')) {
          return http.Response(
            jsonEncode({
              'status': 'downloaded',
              'files': [
                {'id': 1, 'path': '/Sousou no Frieren - 06.mkv'},
                {'id': 2, 'path': '/Sousou no Frieren - 05.mkv'},
              ],
              'links': ['https://real-debrid.com/d/X'],
            }),
            200,
          );
        }
        if (path.endsWith('selectFiles/T')) {
          expect(request.bodyFields['files'], '2');
          return http.Response('', 204);
        }
        if (path.endsWith('unrestrict/link')) {
          return http.Response('{"download":"https://dl.rd/x.mkv"}', 200);
        }
        return http.Response('{}', 404); // ani.zip unaware
      });
      final source = TorrentSource(
        net: FakeNet({
          'Frieren+05': rss([
            (
              '[SubsPlease] Sousou no Frieren - 05 (1080p) [AAAAAAAA].mkv',
              'aaa',
              90,
            ),
            (
              '[SubsPlease] Sousou no Frieren - 06 (1080p) [BBBBBBBB].mkv',
              'bbb',
              90,
            ),
          ]),
          'seeders': rss([
            (
              '[SubsPlease] Sousou no Frieren (01-28) (1080p) [Batch]',
              'ccc',
              40,
            ),
          ]),
        }),
      );
      final media = {
        'id': 1,
        'episodes': 28,
        'title': {'romaji': 'Sousou no Frieren'},
      };
      expect(await source.match(media), '28');
      final streams = await source.streams(
        media,
        const Episode(5, ref: 5),
        dub: false,
      );
      expect(streams.map((s) => s.label), [
        'SubsPlease · 1080p · 90 seeds',
        'SubsPlease · 1080p · batch · 40 seeds',
      ]);
      expect(added, isEmpty);
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(Uri.parse(streams.first.url))
        ..followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.found);
      expect(response.headers.value('location'), 'https://dl.rd/x.mkv');
      expect(added, ['aaa']);
    },
  );

  test(
    'with TorBox alone, only the releases it has cached are offered',
    () async {
      Settings.torboxKey = 'key';
      httpClient = MockClient((request) async {
        if (request.url.path.endsWith('checkcached')) {
          expect(request.url.queryParameters['hash'], 'aaa,bbb');
          return http.Response(
            jsonEncode({
              'success': true,
              'data': [
                {'hash': 'BBB'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final streams =
          await TorrentSource(
            net: FakeNet({
              'q=Show': rss([
                ('[A] Show - 01 (1080p)', 'aaa', 900),
                ('[B] Show - 01 (720p)', 'bbb', 0),
              ]),
            }),
          ).streams(
            {
              'title': {'romaji': 'Show'},
            },
            const Episode(1, ref: 1),
            dub: false,
          );
      expect(streams.map((s) => s.label), ['B · 720p · cached']);
    },
  );

  test('TorBox plays a cached torrent\'s episode file', () async {
    final asked = <String>[];
    httpClient = MockClient((request) async {
      asked.add('${request.method} ${request.url.path}');
      expect(request.headers['Authorization'], 'Bearer key');
      final data = switch (request.url.path) {
        final p when p.endsWith('createtorrent') => {'torrent_id': 7},
        final p when p.endsWith('mylist') => {
          'files': [
            {'id': 0, 'short_name': 'Show - 01 (1080p).mkv'},
            {'id': 1, 'short_name': 'Show - 02 (1080p).mkv'},
          ],
        },
        final p when p.endsWith('requestdl') =>
          'https://cdn.torbox/${request.url.queryParameters['file_id']}',
        _ => null,
      };
      return http.Response(jsonEncode({'success': true, 'data': data}), 200);
    });
    final link = await TorBox('key').link(
      const Release('[G] Show (01-02) [Batch]', 'abc'),
      (name) => episodesIn(name).from == 2,
    );
    expect(link, 'https://cdn.torbox/1');
    expect(asked.first, 'POST /v1/api/torrents/createtorrent');
  });

  test(
    'a torrent Real-Debrid hasn\'t cached is removed, and isn\'t played',
    () async {
      Settings.realDebridKey = 'key';
      final asked = <String>[];
      httpClient = MockClient((request) async {
        asked.add('${request.method} ${request.url.path.split('/1.0/').last}');
        return switch (request.url.path) {
          final p when p.endsWith('addMagnet') => http.Response(
            '{"id":"T"}',
            201,
          ),
          final p when p.contains('info') => http.Response(
            jsonEncode({
              'status': 'downloading',
              'files': [
                {'id': 1, 'path': '/Show - 01.mkv'},
              ],
            }),
            200,
          ),
          _ => http.Response('', 204),
        };
      });
      await expectLater(
        TorrentSource.play(const Release('[G] Show - 01', 'abc'), (_) => true),
        throwsStateError,
      );
      expect(asked, contains('POST torrents/selectFiles/T'));
      expect(asked.last, 'DELETE torrents/delete/T');
    },
  );

  test('Real-Debrid plays a cached torrent', () async {
    httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('addMagnet')) return http.Response('{"id":"T"}', 201);
      if (path.contains('info')) {
        return http.Response(
          jsonEncode({
            'status': 'downloaded',
            'files': [
              {'id': 1, 'path': '/Show - 01.mkv'},
            ],
            'links': ['https://real-debrid.com/d/X'],
          }),
          200,
        );
      }
      if (path.endsWith('unrestrict/link')) {
        expect(request.bodyFields['link'], 'https://real-debrid.com/d/X');
        return http.Response('{"download":"https://dl.rd/x.mkv"}', 200);
      }
      return http.Response('', 204);
    });
    expect(
      await RealDebrid('key')
          .link(const Release('[G] Show - 01', 'abc'), (_) => true),
      'https://dl.rd/x.mkv',
    );
  });

  test('without a debrid service, a release streams from rqbit, one torrent at a time', () async {
    final program = File(
      '${(await Directory.systemTemp.createTemp()).path}/rqbit',
    )..createSync();
    addTearDown(() => program.parent.delete(recursive: true));
    PeerEngine.program = program.path;
    PeerEngine.api = Future.value('http://rqbit.test');
    final asked = <String>[];
    // Like rqbit: a torrent added again keeps the files it had, and only one already running can change them.
    final chosen = <String, List<int>>{};
    httpClient = MockClient((request) async {
      final url = request.url;
      asked.add(url.hasQuery ? '${url.path}?${url.query}' : url.path);
      if (url.path == '/torrents') {
        final hash = request.body.split('btih:')[1].split('&')[0];
        final only = url.queryParameters['only_files'];
        final files = url.queryParameters['list_only'] == 'true'
            ? [0, 1]
            : chosen.putIfAbsent(hash, () => [int.parse(only!)]);
        return http.Response(
          jsonEncode({
            'id': hash == 'bbb' ? 2 : 1,
            'details': {
              'files': [
                for (final (i, n) in ['01', '02'].indexed)
                  {
                    'name': 'Batch/Show - $n.mkv',
                    'components': ['Batch', 'Show - $n.mkv'],
                    'included': files.contains(i),
                  },
              ],
            },
          }),
          200,
        );
      }
      if (url.path.endsWith('update_only_files')) {
        expect(request.headers['content-type'], startsWith('application/json'));
        chosen['bbb'] = [
          ...(jsonDecode(request.body)['only_files'] as List).cast<int>(),
        ];
      }
      return http.Response('{}', 200);
    });
    bool episode(String name, num n) => episodesIn(name).from == n;
    expect(
      await TorrentSource.play(
        const Release('[G] Show (01-02)', 'aaa'),
        (f) => episode(f, 2),
      ),
      'http://rqbit.test/torrents/1/stream/1',
    );
    expect(asked, [
      '/torrents?list_only=true',
      '/torrents?overwrite=true&only_files=1',
    ]);
    asked.clear();
    expect(
      await TorrentSource.play(
        const Release('[H] Show (01-02)', 'bbb'),
        (f) => episode(f, 2),
      ),
      'http://rqbit.test/torrents/2/stream/1',
    );
    expect(asked[1], '/torrents/aaa/delete');
    asked.clear();
    // The next episode, out of the batch already playing.
    expect(
      await TorrentSource.play(
        const Release('[H] Show (01-02)', 'bbb'),
        (f) => episode(f, 1),
      ),
      'http://rqbit.test/torrents/2/stream/0',
    );
    expect(asked.last, '/torrents/2/update_only_files');
    expect(chosen['bbb'], [0]);
  });
}
