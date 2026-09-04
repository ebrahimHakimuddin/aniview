import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'anilist.dart';
import 'hls_proxy.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';

enum DownloadStatus { queued, downloading, done, failed }

class Download {
  Download({
    required this.media,
    required this.source,
    required this.number,
    required this.dub,
    required this.ref,
    this.title,
    this.thumbnail,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.bytes = 0,
    this.error,
    this.subtitles = const [],
    this.skips = const [],
  });

  final Map media;
  final String source;
  final num number;
  final bool dub;
  final Object ref;
  final String? title, thumbnail;
  DownloadStatus status;
  double progress;
  int bytes;
  String? error;
  List<Subtitle> subtitles; // file names inside the download folder
  List<SkipTime> skips;

  String get id => '${media['id']}-${epNumber(number)}-${dub ? 'dub' : 'sub'}';

  Episode get episode =>
      Episode(number, title: title, thumbnail: thumbnail, ref: ref);

  Map<String, dynamic> toJson() => {
    'media': media,
    'source': source,
    'number': number,
    'dub': dub,
    'ref': ref,
    'title': title,
    'thumbnail': thumbnail,
    'status': status.name,
    'progress': progress,
    'bytes': bytes,
    'error': error,
    'subtitles': [
      for (final s in subtitles) {'label': s.label, 'file': s.url},
    ],
    'skips': [
      for (final s in skips)
        {
          'type': s.type.name,
          'start': s.start.inMilliseconds,
          'end': s.end.inMilliseconds,
        },
    ],
  };

  factory Download.fromJson(Map json) => Download(
    media: json['media'],
    source: json['source'],
    number: json['number'],
    dub: json['dub'] == true,
    ref: json['ref'],
    title: json['title'],
    thumbnail: json['thumbnail'],
    status:
        DownloadStatus.values.asNameMap()[json['status']] ??
        DownloadStatus.failed,
    progress: (json['progress'] as num? ?? 0).toDouble(),
    bytes: json['bytes'] ?? 0,
    error: json['error'],
    subtitles: [
      for (final s in json['subtitles'] as List? ?? const [])
        Subtitle(s['label'], s['file']),
    ],
    skips: [
      for (final s in json['skips'] as List? ?? const [])
        SkipTime(
          SkipType.values.byName(s['type']),
          Duration(milliseconds: s['start']),
          Duration(milliseconds: s['end']),
        ),
    ],
  );
}

/// Episodes saved on the device. An HLS stream is stored as a local playlist plus its segment, key and subtitle
/// files, so offline playback works exactly like streaming. Downloads run one at a time while the app is open.
// ponytail: no foreground service, so Android may pause a download when the app is backgrounded for long;
// unfinished segments resume on the next launch.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  final List<Download> items = [];
  late Directory _root;
  Download? _active;
  Completer<void>? _activeDone;
  bool _running = false, _cancel = false;
  Future<void> _saving = Future.value();
  static const _notifications = MethodChannel('aniview/downloads');
  var _notifiedPercent = -1;
  var _notifiedAt = DateTime(0);

  Future<void> load() async {
    _root = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/downloads',
    );
    await _root.create(recursive: true);
    final index = File('${_root.path}/index.json');
    if (await index.exists()) {
      try {
        items.addAll([
          for (final json in jsonDecode(await index.readAsString()) as List)
            Download.fromJson(json),
        ]);
      } catch (
        _
      ) {} // unreadable index: start fresh rather than crash on launch
    }
    for (final d in items.where(
      (d) => d.status == DownloadStatus.downloading,
    )) {
      d.status = DownloadStatus.queued; // interrupted when the app closed
    }
    _pump();
  }

  Directory _dir(Download d) => Directory('${_root.path}/${d.id}');

  int get totalBytes => items.fold(0, (sum, d) => sum + d.bytes);

  /// A finished download of this episode; any audio when [dub] is null.
  Download? find(Map media, num number, {bool? dub}) => items
      .where(
        (d) =>
            d.media['id'] == media['id'] &&
            d.number == number &&
            d.status == DownloadStatus.done &&
            (dub == null || d.dub == dub),
      )
      .firstOrNull;

  /// The download entry (in any state) for this episode and audio.
  Download? entry(Map media, num number, bool dub) => items
      .where(
        (d) =>
            d.media['id'] == media['id'] && d.number == number && d.dub == dub,
      )
      .firstOrNull;

  /// Finished downloads of a show, one per episode, in order.
  List<Download> forMedia(Map media) {
    final byNumber = <num, Download>{};
    for (final d in items) {
      if (d.media['id'] == media['id'] && d.status == DownloadStatus.done) {
        byNumber.putIfAbsent(d.number, () => d);
      }
    }
    return byNumber.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
  }

  VideoStream streamFor(Download d) {
    final dir = _dir(d).path;
    return VideoStream(
      'Downloaded',
      '$dir/index.m3u8',
      const {},
      subtitles: [
        for (final s in d.subtitles) Subtitle(s.label, '$dir/${s.url}'),
      ],
      skips: d.skips,
    );
  }

  void enqueue(Map media, String source, Episode episode, {required bool dub}) {
    if (entry(media, episode.number, dub) case final existing?) {
      return retry(existing);
    }
    items.add(
      Download(
        media: media,
        source: source,
        number: episode.number,
        dub: dub,
        ref: episode.ref,
        title: episode.title,
        thumbnail: episode.thumbnail,
      ),
    );
    _notify(save: true);
    _pump();
  }

  void retry(Download d) {
    if (d.status != DownloadStatus.failed) return;
    d
      ..status = DownloadStatus.queued
      ..error = null;
    _notify(save: true);
    _pump();
  }

  Future<void> remove(Download d) async {
    final activeDone = identical(_active, d) ? _activeDone?.future : null;
    if (activeDone != null) _cancel = true;
    items.remove(d);
    _notify(save: true);
    await activeDone;
    try {
      await _dir(d).delete(recursive: true);
    } catch (_) {} // nothing on disk yet
  }

  Future<void> removeAll() async {
    final activeDone = _activeDone?.future;
    if (activeDone != null) _cancel = true;
    items.clear();
    _notify(save: true);
    await activeDone;
    for (final entity in await _root.list().toList()) {
      if (entity is Directory) await entity.delete(recursive: true);
    }
  }

  /// System notification for the running download, throttled because Android drops rapid updates.
  void _notifyProgress() {
    final d = _active;
    if (d == null) return;
    final percent = (d.progress * 100).floor();
    final now = DateTime.now();
    if (percent == _notifiedPercent ||
        (percent > 0 &&
            now.difference(_notifiedAt) < const Duration(milliseconds: 700))) {
      return;
    }
    _notifiedPercent = percent;
    _notifiedAt = now;
    _post('progress', d, {'percent': percent});
  }

  void _post(
    String state,
    Download d, [
    Map<String, Object?> extra = const {},
  ]) => _notifications
      .invokeMethod(state, {
        'title': '${titleOf(d.media)} · Episode ${epNumber(d.number)}',
        ...extra,
      })
      .catchError((Object _) => null); // no notifications off Android

  void _notify({bool save = false}) {
    notifyListeners();
    _notifyProgress();
    if (!save) return;
    final json = jsonEncode([for (final d in items) d.toJson()]);
    _saving = _saving.then((_) async {
      try {
        await File('${_root.path}/index.json').writeAsString(json);
      } catch (_) {}
    });
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = items
            .where((d) => d.status == DownloadStatus.queued)
            .firstOrNull;
        if (next == null) break;
        await _download(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _download(Download d) async {
    final done = _activeDone = Completer<void>();
    _active = d;
    _cancel = false;
    _notifiedPercent = -1;
    d
      ..status = DownloadStatus.downloading
      ..progress = 0
      ..bytes = 0
      ..error = null;
    _notify(save: true);
    try {
      final all = await sites.catchError((Object _) => sites = topSources());
      final source = all.where((s) => s.name == d.source).firstOrNull;
      if (source == null) {
        throw Exception('${d.source} is no longer one of the top sites');
      }
      final streams = await source.streams(d.media, d.episode, dub: d.dub);
      if (streams.isEmpty) {
        throw Exception('No ${d.dub ? 'dub' : 'sub'} servers for this episode');
      }
      final stream = streams.first;
      final dir = await _dir(d).create(recursive: true);
      final length = await _saveHls(d, stream, dir);
      d.subtitles = await _saveSubtitles(stream, dir);
      final community = await aniSkip(d.media['idMal'], d.number, length);
      d
        ..skips = community.isNotEmpty ? community : stream.skips
        ..status = DownloadStatus.done
        ..progress = 1;
    } catch (e) {
      if (_cancel) return; // removed while downloading
      d
        ..status = DownloadStatus.failed
        ..error = e is CloudflareChallenge
            ? '${d.source} needs a quick verification: play any episode from it once, then retry'
            : friendlyError(e);
    } finally {
      _post(_cancel ? 'cancel' : d.status.name, d, {'text': d.error});
      _active = null;
      _activeDone = null;
      if (!_cancel) _notify(save: true);
      done.complete();
    }
  }

  /// Saves the best variant as index.m3u8 plus local files (4 at a time); returns the episode length.
  Future<Duration> _saveHls(
    Download d,
    VideoStream stream,
    Directory dir,
  ) async {
    var url = Uri.parse(stream.url);
    var playlist = await fetch('$url', headers: stream.headers);
    if (playlist.contains('#EXT-X-STREAM-INF')) {
      url = url.resolve(bestVariant(playlist));
      playlist = await fetch('$url', headers: stream.headers);
    }
    final (local, files, length) = localizePlaylist(playlist, url);
    final queue = files.entries.toList().iterator;
    var done = 0;
    var stop = false;

    Future<void> worker() async {
      try {
        while (!stop && queue.moveNext()) {
          final MapEntry(key: name, value: remote) = queue.current;
          if (_cancel) throw _Cancelled();
          final file = File('${dir.path}/$name');
          if (!await file.exists()) {
            final bytes = await _fetchWithRetry('$remote', stream.headers);
            final part = File('${file.path}.part');
            await part.writeAsBytes(
              name.endsWith('.ts') ? stripToTs(bytes) : bytes,
              flush: true,
            );
            await part.rename(
              file.path,
            ); // only complete files count when resuming
          }
          d.bytes += await file.length();
          d.progress = ++done / files.length;
          _notify();
        }
      } catch (_) {
        stop = true;
        rethrow;
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    await File('${dir.path}/index.m3u8').writeAsString(local);
    return length;
  }

  Future<List<Subtitle>> _saveSubtitles(
    VideoStream stream,
    Directory dir,
  ) async {
    final wanted = {Settings.subtitleLanguage, 'English'};
    final saved = <Subtitle>[];
    for (final subtitle in stream.subtitles.where(
      (s) => wanted.any(s.label.startsWith),
    )) {
      try {
        final name = 'sub${saved.length}.vtt';
        await File('${dir.path}/$name')
            .writeAsBytes(await _fetchWithRetry(subtitle.url, stream.headers));
        saved.add(Subtitle(subtitle.label, name));
      } catch (_) {} // subtitles are optional for offline playback
    }
    return saved;
  }
}

class _Cancelled implements Exception {}

Future<Uint8List> _fetchWithRetry(
  String url,
  Map<String, String> headers,
) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await fetchBytes(url, headers: headers);
    } catch (_) {
      if (attempt == 3) rethrow;
      await Future.delayed(Duration(seconds: attempt));
    }
  }
}

/// URI of the highest-bandwidth variant in a master playlist.
// ponytail: separate audio renditions (#EXT-X-MEDIA) aren't saved; the supported hosts mux audio into the variant
String bestVariant(String master) {
  final lines = master.split('\n').map((l) => l.trim()).toList();
  String? best;
  var bestBandwidth = -1;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    final bandwidth =
        int.tryParse(
          RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?[1] ?? '',
        ) ??
        0;
    final uri = lines
        .skip(i + 1)
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    if (uri.isNotEmpty && bandwidth > bestBandwidth) {
      best = uri;
      bestBandwidth = bandwidth;
    }
  }
  return best ??
      (throw const FormatException('The stream has no playable variant'));
}

/// Rewrites a media playlist to local file names. Returns the playlist, the files to fetch (by local name)
/// and the total length from #EXTINF.
(String, Map<String, Uri>, Duration) localizePlaylist(
  String playlist,
  Uri base,
) {
  final out = StringBuffer();
  final files = <String, Uri>{};
  var seconds = 0.0;
  var segments = 0, keys = 0;
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('#')) {
      final name = 'seg${(segments++).toString().padLeft(5, '0')}.ts';
      files[name] = base.resolve(line);
      out.writeln(name);
      continue;
    }
    if (line.startsWith('#EXTINF:')) {
      seconds += double.tryParse(line.substring(8).split(',').first) ?? 0;
    }
    out.writeln(
      line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
        final name = 'key${keys++}.bin';
        files[name] = base.resolve(m[1]!);
        return 'URI="$name"';
      }),
    );
  }
  return ('$out', files, Duration(milliseconds: (seconds * 1000).round()));
}

String formatBytes(int bytes) => bytes < 1 << 20
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : bytes < 1 << 30
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
    : '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
