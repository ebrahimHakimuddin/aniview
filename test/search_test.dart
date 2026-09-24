import 'dart:async';

import 'package:aniview/anilist.dart';
import 'package:aniview/search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'waits for typing to pause, skips one letter, drops replaced answers',
    () async {
      final asked = <String>[];
      final answers = <String, Completer<(List, bool)>>{};
      final search = SearchSession(
        pause: const Duration(milliseconds: 20),
        fetch: (query, _, _) {
          asked.add(query);
          return (answers[query] = Completer()).future;
        },
      );

      search.type('n');
      search.type('na');
      search.type('nar');
      await Future.delayed(const Duration(milliseconds: 40));
      expect(asked, ['nar']); // one search, after the pause, never for "n"

      search.submit('naruto');
      await Future.delayed(Duration.zero);
      answers['naruto']!.complete((['Naruto'], false));
      answers['nar']!.complete((['stale'], false)); // arrives late
      await Future.delayed(Duration.zero);
      expect(search.items, ['Naruto']);
      expect(search.loading, isFalse);
    },
  );

  test(
    'browses by filters alone, pages on, and fetches after a short page',
    () async {
      final pages = <int>[];
      final search = SearchSession(
        pause: Duration.zero,
        fetch: (_, _, page) async {
          pages.add(page);
          // A short first page (MyAnimeList after filtering), then full ones.
          return (List.filled(page == 1 ? 5 : 40, page), page < 3);
        },
      );
      search.submit(''); // no text and no filters: nothing to search
      await Future.delayed(Duration.zero);
      expect(pages, isEmpty);

      search.filter(const SearchFilters(genres: {'Action'}), '');
      await Future.delayed(const Duration(milliseconds: 10));
      expect(pages, [1, 2]); // the short page pulled in the next
      await search.more();
      expect(pages, [1, 2, 3]);
      await search.more();
      expect(pages, [1, 2, 3]); // none left
      expect(search.items.length, 5 + 40 + 40);

      search.clear();
      expect(search.items, isEmpty);
      expect((search.searched, search.filters.count), (false, 0));
    },
  );
}
