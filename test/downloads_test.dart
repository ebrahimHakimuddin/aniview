import 'dart:convert';

import 'package:aniview/downloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one unreadable download is skipped, not the whole list', () {
    final good = Download(
      media: {'id': 1},
      source: 'Anikoto',
      number: 3,
      dub: false,
      ref: 'r',
    ).toJson();
    final downloads = readIndex(
      jsonEncode([
        good,
        {...good, 'number': 'three'}, // wrong type
        {'source': 'Anikoto'}, // missing fields
        'not a map',
      ]),
    );
    expect([for (final d in downloads) (d.media['id'], d.number)], [(1, 3)]);
  });
}
