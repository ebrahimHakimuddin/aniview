import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Subtitle formats the players read, by the extension a file of them goes by.
const subtitleExts = {'vtt', 'srt', 'ass', 'ssa', 'ttml', 'dfxp'};

/// [url]'s subtitle format from its extension; null when its address doesn't say (`…/subs?id=3`).
String? subtitleExtOf(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  return subtitleExts.contains(ext) ? ext : null;
}

/// A subtitle file's format from what's in it, for addresses that don't say.
String sniffSubtitle(List<int> bytes) {
  final head = utf8
      .decode(bytes.take(4096).toList(), allowMalformed: true)
      .replaceFirst('\uFEFF', '')
      .trimLeft();
  if (head.startsWith('WEBVTT')) return 'vtt';
  if (head.contains('[Script Info]') || head.contains('[Events]')) return 'ass';
  if (head.startsWith('<')) return 'ttml';
  if (RegExp(r'\d+:\d\d:\d\d,\d{3}\s*-->').hasMatch(head)) return 'srt';
  return 'vtt';
}

/// One line of dialogue on screen from [start] to [end].
typedef Cue = ({Duration start, Duration end, String text});

/// The cues of a subtitle file in [format] (see [subtitleExts]), as plain text: styling, positions and drawings
/// dropped. TTML gives none.
List<Cue> parseCues(String text, String format) => switch (format) {
  'ass' || 'ssa' => _assCues(text),
  'vtt' || 'srt' => _timedBlocks(text),
  _ => const [],
};

final _time = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})');

Duration? _parseTime(String s) {
  final m = _time.firstMatch(s);
  if (m == null) return null;
  return Duration(
    hours: int.parse(m[1] ?? '0'),
    minutes: int.parse(m[2]!),
    seconds: int.parse(m[3]!),
    // "5" in ".5" is 500ms, as is "50" in ASS's centiseconds.
    milliseconds: int.parse(m[4]!.padRight(3, '0')),
  );
}

String _plain(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .trim();

/// SRT and WebVTT: a "start --> end" line, then the text up to a blank line.
List<Cue> _timedBlocks(String text) {
  final cues = <Cue>[];
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final [from, ...rest] = lines[i].split('-->');
    if (rest.isEmpty) continue;
    final start = _parseTime(from), end = _parseTime(rest.first);
    if (start == null || end == null) continue;
    final body = <String>[];
    while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
      body.add(_plain(lines[++i]));
    }
    final line = body.where((l) => l.isNotEmpty).join('\n');
    if (line.isNotEmpty && end > start) {
      cues.add((start: start, end: end, text: line));
    }
  }
  return cues;
}

/// ASS/SSA: the Dialogue lines of [Events], read by its Format line.
List<Cue> _assCues(String text) {
  final cues = <Cue>[];
  var fields = [
    'Layer',
    'Start',
    'End',
    'Style',
    'Name',
    'MarginL',
    'MarginR',
    'MarginV',
    'Effect',
    'Text',
  ];
  var events = false;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      events = line.toLowerCase() == '[events]';
      continue;
    }
    if (!events) continue;
    if (line.startsWith('Format:')) {
      fields = [for (final f in line.substring(7).split(',')) f.trim()];
      continue;
    }
    if (!line.startsWith('Dialogue:')) continue;
    // Text is last and may hold commas of its own.
    final parts = line.substring(9).split(',');
    if (parts.length < fields.length) continue;
    final values = [
      ...parts.take(fields.length - 1),
      parts.skip(fields.length - 1).join(','),
    ];
    String field(String name) => values[fields.indexOf(name)].trim();
    if (!fields.contains('Start') || !fields.contains('Text')) return cues;
    final body = field('Text');
    // Vector drawings (signs drawn with \p1) have no words to show.
    if (RegExp(r'\\p[1-9]').hasMatch(body)) continue;
    final words = body
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(RegExp(r'\\[Nn]'), '\n')
        .replaceAll(r'\h', ' ')
        .trim();
    final start = _parseTime(field('Start')), end = _parseTime(field('End'));
    if (words.isEmpty || start == null || end == null || end <= start) continue;
    cues.add((start: start, end: end, text: words));
  }
  return cues;
}

/// Language codes (ISO 639-2) for the names extensions and sites label subtitles with.
const _languages = {
  'english': 'eng',
  'spanish': 'spa',
  'español': 'spa',
  'portuguese': 'por',
  'português': 'por',
  'french': 'fra',
  'français': 'fra',
  'german': 'deu',
  'deutsch': 'deu',
  'italian': 'ita',
  'russian': 'rus',
  'arabic': 'ara',
  'japanese': 'jpn',
  'indonesian': 'ind',
  'thai': 'tha',
  'vietnamese': 'vie',
  'chinese': 'zho',
  'korean': 'kor',
  'turkish': 'tur',
  'polish': 'pol',
  'hindi': 'hin',
  'malay': 'msa',
  'dutch': 'nld',
  'filipino': 'fil',
};
const _shortCodes = {
  'en': 'eng',
  'es': 'spa',
  'pt': 'por',
  'fr': 'fra',
  'de': 'deu',
  'it': 'ita',
  'ru': 'rus',
  'ar': 'ara',
  'ja': 'jpn',
  'id': 'ind',
  'th': 'tha',
  'vi': 'vie',
  'zh': 'zho',
  'ko': 'kor',
  'tr': 'tur',
  'pl': 'pol',
  'hi': 'hin',
  'ms': 'msa',
};

/// The English name of language [code] ("eng", "en"), for labels; null when unknown.
String? languageName(String code) {
  final iso = languageCode(code);
  for (final MapEntry(:key, :value) in _languages.entries) {
    if (value == iso) return key[0].toUpperCase() + key.substring(1);
  }
  return null;
}

/// The ISO 639-2 code for a subtitle labelled [label] ("English", "Spanish (Latin)", "en-US"); "und" when unknown.
String languageCode(String label) {
  final l = label.toLowerCase().trim();
  for (final MapEntry(:key, :value) in _languages.entries) {
    if (l.startsWith(key)) return value;
  }
  final short = l.split(RegExp(r'[-_ ]')).first;
  if (_shortCodes[short] case final code?) return code;
  if (RegExp(r'^[a-z]{3}$').hasMatch(short)) return short;
  return 'und';
}

/// Adds [tracks] (label and cues) to the MP4 at [path] as text subtitle tracks (tx3g, as players and ffmpeg's
/// mov_text read), without rewriting the video: the old movie header becomes free space, and the subtitle text and
/// a new header with the extra tracks go on the end.
// ponytail: refuses fragmented MP4s (none of ours are); they'd need the tracks in every fragment
Future<void> embedSubtitles(
  String path,
  List<(String label, List<Cue> cues)> tracks,
) async {
  tracks = [
    for (final t in tracks)
      if (t.$2.isNotEmpty) t,
  ];
  if (tracks.isEmpty) return;
  final file = await File(path)
      .open(mode: FileMode.append); // read-write, nothing cut
  try {
    final (moovAt, moov) = await _findMoov(file);
    final children = _boxes(moov, 8);
    if (children.any((b) => b.type == 'mvex')) {
      throw const FormatException('Fragmented MP4');
    }
    final mvhd = children.firstWhere((b) => b.type == 'mvhd');
    final v1 = moov[mvhd.start + 8] == 1;
    final view = ByteData.sublistView(moov);
    final scale = view.getUint32(mvhd.start + (v1 ? 28 : 20));
    final movieLength = v1
        ? view.getUint64(mvhd.start + 32)
        : view.getUint32(mvhd.start + 24);
    final movieMs = movieLength * 1000 ~/ scale;
    final nextIdAt = mvhd.start + mvhd.size - 4;
    var nextId = view.getUint32(nextIdAt);

    // Each track's samples back to back in one new mdat, one chunk per track.
    final mdatAt = await file.length();
    final samples = BytesBuilder(copy: false);
    final traks = BytesBuilder(copy: false);
    for (final (label, cues) in tracks) {
      final (data, durations) = _samples(cues, movieMs);
      final offset = mdatAt + 16 + samples.length;
      samples.add(data.expand((s) => s).toList());
      traks.add(
        _trak(
          id: nextId++,
          label: label,
          sizes: [for (final s in data) s.length],
          durations: durations,
          offset: offset,
          movieDuration: durations.fold(0, (a, b) => a + b) * scale ~/ 1000,
        ),
      );
    }
    view.setUint32(nextIdAt, nextId);
    await file.setPosition(
      mdatAt,
    ); // reading the header left it wherever that was
    // A 64-bit mdat header, so the offsets above hold whatever the size.
    await file.writeFrom(
      _u32(1) + latin1.encode('mdat') + _u64(16 + samples.length),
    );
    await file.writeFrom(samples.takeBytes());
    final body = traks.takeBytes();
    await file.writeFrom(
      _u32(moov.length + body.length) + latin1.encode('moov'),
    );
    await file.writeFrom(Uint8List.sublistView(moov, 8));
    await file.writeFrom(body);
    // Only now, with the new header whole: the old one's type turns to "free", leaving every offset in place.
    await file.setPosition(moovAt + 4);
    await file.writeFrom(latin1.encode('free'));
  } finally {
    await file.close();
  }
}

/// The top-level moov box: where it starts, and its bytes.
Future<(int, Uint8List)> _findMoov(RandomAccessFile file) async {
  final length = await file.length();
  var at = 0;
  while (at + 8 <= length) {
    await file.setPosition(at);
    final head = ByteData.sublistView(await file.read(16));
    var size = head.getUint32(0);
    final type = latin1.decode(
      head.buffer.asUint8List(head.offsetInBytes + 4, 4),
    );
    if (size == 1) size = head.getUint64(8);
    if (size == 0) size = length - at;
    if (type == 'moov') {
      if (size > 64 << 20) {
        throw const FormatException('Movie header too large');
      }
      await file.setPosition(at);
      return (at, await file.read(size));
    }
    if (size < 8) break;
    at += size;
  }
  throw const FormatException('Not an MP4');
}

typedef _Box = ({String type, int start, int size});

/// The boxes inside [data] from [at] on.
List<_Box> _boxes(Uint8List data, int at) {
  final view = ByteData.sublistView(data);
  final boxes = <_Box>[];
  while (at + 8 <= data.length) {
    final size = view.getUint32(at);
    if (size < 8) break;
    boxes.add((
      type: latin1.decode(data.sublist(at + 4, at + 8)),
      start: at,
      size: size,
    ));
    at += size;
  }
  return boxes;
}

/// tx3g samples covering [0, end): the text on screen in each stretch between cue changes (overlapping cues shown
/// together), empty between them. Durations in milliseconds.
(List<List<int>>, List<int>) _samples(List<Cue> cues, int endMs) {
  final edges = <int>{0};
  for (final c in cues) {
    edges
      ..add(c.start.inMilliseconds.clamp(0, endMs))
      ..add(c.end.inMilliseconds.clamp(0, endMs));
  }
  final times = edges.toList()..sort();
  final data = <List<int>>[], durations = <int>[];
  for (var i = 0; i + 1 < times.length; i++) {
    final from = times[i], to = times[i + 1];
    final text = [
      for (final c in cues)
        if (c.start.inMilliseconds <= from && c.end.inMilliseconds >= to)
          c.text,
    ].join('\n');
    final bytes = utf8.encode(text);
    // Repeated text (or silence) runs on in the sample before.
    if (data.isNotEmpty && _sameBytes(data.last.skip(2).toList(), bytes)) {
      durations.last += to - from;
      continue;
    }
    data.add([..._u16(bytes.length), ...bytes]);
    durations.add(to - from);
  }
  return (data, durations);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _box(String type, List<int> body) => [
  ..._u32(8 + body.length),
  ...latin1.encode(type),
  ...body,
];

List<int> _full(String type, List<int> body, [int flags = 0]) => _box(type, [
  0,
  (flags >> 16) & 255,
  (flags >> 8) & 255,
  flags & 255,
  ...body,
]);

List<int> _u16(int v) => [(v >> 8) & 255, v & 255];
List<int> _u32(int v) => [
  (v >> 24) & 255,
  (v >> 16) & 255,
  (v >> 8) & 255,
  v & 255,
];
List<int> _u64(int v) => [..._u32(v >> 32), ..._u32(v & 0xFFFFFFFF)];

List<int> _trak({
  required int id,
  required String label,
  required List<int> sizes,
  required List<int> durations,
  required int offset,
  required int movieDuration,
}) {
  final total = durations.fold(0, (a, b) => a + b);
  final language = languageCode(label);
  final packed = language.codeUnits.fold(0, (v, c) => (v << 5) | (c - 0x60));
  const unity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
  final sampleEntry = _box('tx3g', [
    0, 0, 0, 0, 0, 0, ..._u16(1), // reserved, data reference 1
    ..._u32(0), // display flags
    1, 0xFF, // centred, at the bottom
    ..._u32(0), // no background
    ...List.filled(8, 0), // default text box
    ..._u16(0),
    ..._u16(0),
    ..._u16(1),
    0,
    18,
    ..._u32(0xFFFFFFFF), // style: font 1, 18pt, white
    ..._box('ftab', [..._u16(1), ..._u16(1), 5, ...latin1.encode('Serif')]),
  ]);
  return _box('trak', [
    ..._full('tkhd', [
      ..._u32(0), ..._u32(0), ..._u32(id), ..._u32(0), ..._u32(movieDuration),
      ...List.filled(8, 0),
      ..._u16(0),
      ..._u16(2),
      ..._u16(0),
      ..._u16(0), // layer, alternate group (subtitles), volume
      for (final m in unity) ..._u32(m),
      ..._u32(0), ..._u32(0),
    ], 3), // enabled, in the movie
    ..._box('mdia', [
      ..._full('mdhd', [
        ..._u32(0),
        ..._u32(0),
        ..._u32(1000),
        ..._u32(total),
        ..._u16(packed),
        ..._u16(0),
      ]),
      // The handler's name is the track's name in players that show one.
      ..._full('hdlr', [
        ..._u32(0),
        ...latin1.encode('sbtl'),
        ...List.filled(12, 0),
        ...utf8.encode(label),
        0,
      ]),
      ..._box('minf', [
        ..._full('nmhd', []),
        ..._box('dinf', [
          ..._full('dref', [..._u32(1), ..._full('url ', [], 1)]),
        ]),
        ..._box('stbl', [
          ..._full('stsd', [..._u32(1), ...sampleEntry]),
          ..._full('stts', [
            ..._u32(durations.length),
            for (final d in durations) ...[..._u32(1), ..._u32(d)],
          ]),
          ..._full('stsc', [
            ..._u32(1),
            ..._u32(1),
            ..._u32(sizes.length),
            ..._u32(1),
          ]),
          ..._full('stsz', [
            ..._u32(0),
            ..._u32(sizes.length),
            for (final s in sizes) ..._u32(s),
          ]),
          ..._full('co64', [..._u32(1), ..._u64(offset)]),
        ]),
      ]),
    ]),
  ]);
}

// FFmpeg treats padded blank lines in Netflix WebVTT headers as cue IDs and
// can discard every following cue. Keep actual text and timing unchanged.
String normalizeWebVtt(String text) =>
    text.replaceAll(RegExp(r'^[ \t]+\r?$', multiLine: true), '');
