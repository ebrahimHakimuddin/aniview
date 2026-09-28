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

  test('chosen folder remains attached to a saved episode after restart', () {
    final original = Download(
      media: {'id': 7},
      source: 'Anikoto',
      number: 12,
      dub: false,
      ref: 'r',
      status: DownloadStatus.done,
      storageUri: 'content://com.android.externalstorage.documents/tree/primary%3AAnime',
    );
    final restored = readIndex(jsonEncode([original.toJson()])).single;
    expect(restored.storageUri, original.storageUri);
    expect(restored.status, DownloadStatus.done);
    final stream = Downloads.instance.streamFor(restored);
    expect(stream.isLocal, isTrue);
    expect(stream.isHls, isTrue);
  });
}
