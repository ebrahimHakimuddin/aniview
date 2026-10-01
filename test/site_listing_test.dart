import 'package:aniview/site_listing.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A site whose answers, and how many times it's blocked first, the test decides.
class FakeSource extends Source {
  FakeSource() : super('Fake', 'https://fake.test');

  String? guess = '/guessed';
  int blocked =
      0; // requests refused with a Cloudflare check before one is answered
  final asked = <String>[];

  Future<T> _answer<T>(String what, T value) async {
    asked.add(what);
    if (blocked > 0) {
      blocked--;
      throw CloudflareChallenge('https://fake.test/');
    }
    return value;
  }

  @override
  Future<List<SearchResult>> search(String query) => _answer('search', []);

  @override
  Future<String?> match(Map media) => _answer('match', guess);

  @override
  Future<List<Episode>> episodesOf(String id) =>
      _answer('episodes $id', [Episode(1, ref: id), Episode(2, ref: id)]);

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) => _answer('streams ${dub ? 'dub' : 'sub'}', [
    VideoStream('Server', 'https://cdn.test/${dub ? 'dub' : 'sub'}.m3u8', {}),
  ]);
}

void main() {
  final media = {
    'id': 7,
    'title': {'romaji': 'Show'},
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // ani.zip, which adds titles and art, is optional: loading goes on without it.
    httpClient = MockClient((_) async => http.Response('', 404));
  });

  group('episodes', () {
    test('come from the site\'s own guess at the show', () async {
      final source = FakeSource();
      final episodes = await SiteListing(source, media).episodes();
      expect(episodes.map((e) => e.number), [1, 2]);
      expect(source.asked, contains('episodes /guessed'));
    });

    test(
      'come from the person\'s pick once they\'ve made one, not the guess',
      () async {
        final source = FakeSource();
        await SiteListing(source, media).pick('/chosen');
        final episodes = await SiteListing(source, media).episodes();
        expect(episodes.map((e) => e.ref), ['/chosen', '/chosen']);
        expect(
          source.asked,
          isNot(contains('match')),
        ); // the pick made the guess unnecessary
      },
    );

    test('a pick is for one show on one site', () async {
      final source = FakeSource();
      await SiteListing(source, media).pick('/chosen');
      await SiteListing(source, {'id': 8}).episodes();
      expect(source.asked, contains('episodes /guessed'));
    });

    test('are empty when the site has no match for the show', () async {
      final source = FakeSource()..guess = null;
      expect(await SiteListing(source, media).episodes(), isEmpty);
    });
  });

  group('streams', () {
    test('are the site\'s servers for the audio asked for', () async {
      final source = FakeSource();
      final listing = SiteListing(source, media);
      final dub = await listing.streams(Episode(1, ref: 'x'), dub: true);
      final sub = await listing.streams(Episode(1, ref: 'x'), dub: false);
      expect(dub.single.url, endsWith('dub.m3u8'));
      expect(sub.single.url, endsWith('sub.m3u8'));
    });
  });

  group('a Cloudflare check', () {
    test(
      'is passed by the handler, and the request goes through after it',
      () async {
        final source = FakeSource()..blocked = 1;
        var shown = 0;
        final listing = SiteListing(
          source,
          media,
          onChallenge: (c) async {
            shown++;
            expect(c.url, 'https://fake.test/');
            return true;
          },
        );
        expect(
          await listing.streams(Episode(1, ref: 'x'), dub: false),
          hasLength(1),
        );
        expect(shown, 1);
      },
    );

    test('is thrown as it is when the person doesn\'t pass it', () async {
      final source = FakeSource()..blocked = 1;
      final listing = SiteListing(
        source,
        media,
        onChallenge: (_) async => false,
      );
      await expectLater(
        listing.episodes(),
        throwsA(isA<CloudflareChallenge>()),
      );
    });

    test(
      'is thrown at once with no handler, as in a download with no screen',
      () async {
        final source = FakeSource()..blocked = 1;
        await expectLater(
          SiteListing(source, media).streams(Episode(1, ref: 'x'), dub: false),
          throwsA(isA<CloudflareChallenge>()),
        );
        expect(source.asked, ['streams sub']); // asked once, not retried
      },
    );

    test('is given up on after three passes that don\'t get through', () async {
      final source = FakeSource()..blocked = 100;
      var shown = 0;
      final listing = SiteListing(
        source,
        media,
        onChallenge: (_) async => ++shown > 0,
      );
      await expectLater(
        listing.episodes(),
        throwsA(isA<CloudflareChallenge>()),
      );
      expect(shown, 3);
    });

    test('covers the whole of loading episodes, matching included', () async {
      final source = FakeSource()
        ..blocked = 2; // the guess is blocked, then the episode list
      var shown = 0;
      final listing = SiteListing(
        source,
        media,
        onChallenge: (_) async {
          shown++;
          return true;
        },
      );
      expect((await listing.episodes()).length, 2);
      expect(shown, 2);
    });
  });
}
