import 'dart:async';

import 'package:aniview/exo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final action in ['open', 'stop', 'dispose']) {
    test('obsolete external tracks are cancelled by $action', () async {
      final loader = MediaKitTrackLoader();
      final duration = StreamController<Duration>.broadcast(sync: true);
      addTearDown(duration.close);
      final opened = Completer<void>();
      final commands = <List<String>>[];
      final old = loader.open(
        openMedia: () => opened.future,
        durations: duration.stream,
        duration: () => Duration.zero,
        command: (command) async => commands.add(command),
        subtitles: [
          {'url': 'A.vtt', 'label': 'A'},
        ],
        audios: [
          {'url': 'A.m4a', 'label': 'A'},
        ],
      );
      if (action == 'open') {
        await loader.open(
          openMedia: () async {},
          durations: duration.stream,
          duration: () => Duration.zero,
          command: (c) async => commands.add(c),
          subtitles: [],
          audios: [],
        );
      } else {
        loader.invalidate();
      }
      duration.add(const Duration(seconds: 10));
      opened.complete();
      await old;
      expect(commands, isEmpty);
    });
  }
  test('duration during open is not missed and tracks attach once', () async {
    final loader = MediaKitTrackLoader();
    final duration = StreamController<Duration>.broadcast(sync: true);
    addTearDown(duration.close);
    final commands = <List<String>>[];
    await loader.open(
      openMedia: () async => duration.add(const Duration(seconds: 10)),
      durations: duration.stream,
      duration: () => Duration.zero,
      command: (c) async => commands.add(c),
      subtitles: [
        {'url': 'B.vtt', 'label': 'B'},
      ],
      audios: [
        {'url': 'B.m4a', 'label': 'B'},
      ],
    );
    expect(commands.map((c) => c.first), ['sub-add', 'audio-add']);
  });
}
