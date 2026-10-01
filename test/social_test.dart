import 'package:aniview/social.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads which episodes a discussion thread covers', () {
    expect(episodesIn('[Spoilers] Sousou No Frieren - Episode 27 Discussion'), (
      27,
      27,
    ));
    expect(
      episodesIn(
        '[Spoilers] Sousou No Frieren - Premiere/Episodes 1-4 Discussion',
      ),
      (1, 4),
    );
    expect(episodesIn('[Spoilers] One Punch Man - Episode 3 [Discussion]'), (
      3,
      3,
    ));
    expect(episodesIn('[Spoilers] One punch man episode 4'), (4, 4));
    expect(episodesIn('Frieren OST official out'), isNull);
  });

  test('finds the thread for an episode, ranges included', () {
    final threads = [
      {'id': 1, 'title': 'Premiere/Episodes 1-4 Discussion'},
      {'id': 5, 'title': 'Episode 5 Discussion'},
      {'id': 50, 'title': 'Episode 50 Discussion'},
    ];
    expect(threadForEpisode(threads, 3)?['id'], 1);
    expect(threadForEpisode(threads, 5)?['id'], 5);
    expect(threadForEpisode(threads, 6), isNull);
  });

  test('drops the spoiler tag from thread titles', () {
    expect(
      threadTitle({'title': ' [Spoilers] Show - Episode 2 Discussion '}),
      'Show - Episode 2 Discussion',
    );
  });
}
