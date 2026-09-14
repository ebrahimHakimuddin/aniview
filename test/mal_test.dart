import 'package:aniview/anilist.dart';
import 'package:aniview/mal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps a MAL anime onto the AniList media shape', () {
    final media = MAL.media({
      'id': 21,
      'title': 'One Piece',
      'alternative_titles': {'en': 'One Piece'},
      'main_picture': {'medium': 'm.jpg', 'large': 'l.jpg'},
      'synopsis': 'Pirates.',
      'mean': 8.72,
      'genres': [
        {'id': 1, 'name': 'Action'},
      ],
      'media_type': 'tv',
      'status': 'currently_airing',
      'start_season': {'year': 1999, 'season': 'fall'},
      'num_episodes': 0,
    });

    expect(
      media['id'],
      isNull,
    ); // filled in from ani.zip when the show is opened
    expect(media['idMal'], 21);
    expect(titleOf(media), 'One Piece');
    expect(media['coverImage']['extraLarge'], 'l.jpg');
    expect(
      media['episodes'],
      isNull,
    ); // 0 means "still going", not "no episodes"
    expect(media['averageScore'], 87);
    expect(media['genres'], ['Action']);
    expect(media['format'], 'TV');
    expect(media['status'], 'RELEASING');
    expect(media['season'], 'FALL');
    expect(media['seasonYear'], 1999);
    expect(media['mediaListEntry'], isNull);
  });

  test('filters MAL results the way AniList would', () {
    final media = {
      'season': 'FALL',
      'seasonYear': 1999,
      'format': 'TV',
      'status': 'RELEASING',
      'genres': ['Action', 'Adventure'],
    };
    expect(const SearchFilters().matches(media), isTrue);
    expect(
      const SearchFilters(
        season: 'FALL',
        year: 1999,
        format: 'TV',
        genres: {'Action', 'Adventure'},
      ).matches(media),
      isTrue,
    );
    expect(const SearchFilters(year: 2000).matches(media), isFalse);
    expect(
      const SearchFilters(genres: {'Action', 'Comedy'}).matches(media),
      isFalse,
    ); // every genre must match
  });
}
