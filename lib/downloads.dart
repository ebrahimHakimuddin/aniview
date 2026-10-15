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
import 'site_listing.dart';
import 'sources.dart';
import 'states.dart';
import 'stream_address.dart';
import 'subtitles.dart';
import 'platform.dart';

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
    this.storageUri,
    this.video,
    this.galleryUri,
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
  String? storageUri;

  /// The episode's MP4 inside its folder; null while it's still (or, made before MP4s, only) an HLS playlist.
  String? video;

  /// The copy saved to the gallery, deleted with the download.
  String? galleryUri;

  /// "Title - Episode 3 (Dub)", safe as a file name.
  String get name =>
      '${titleOf(media)} - Episode ${epNumber(number)}${dub ? ' (Dub)' : ''}'
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '');

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
    'storageUri': storageUri,
    'video': video,
    'galleryUri': galleryUri,
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
    storageUri: json['storageUri'],
    video: json['video'],
    galleryUri: json['galleryUri'],
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

/// The downloads in an index file; an entry that can't be read is skipped, not the whole list (the next save would
/// otherwise write the empty list over every download).
@visibleForTesting
List<Download> readIndex(String json) => [
  for (final entry in jsonDecode(json) as List) ?_tryParse(entry),
];

Download? _tryParse(Object? json) {
  try {
    return Download.fromJson(json as Map);
  } catch (_) {
    return null;
  }
}

/// The queue's state machine, in memory: what's waiting, what's running, what failed, and what a removal during a
/// run cancels. [Downloads] drives it and does the actual fetching.
class DownloadQueue {
  /// [saved] is the list from the previous run; what was downloading when the app closed is queued again.
  DownloadQueue([Iterable<Download> saved = const []]) {
    items.addAll(saved);
    for (final d in items.where(
      (d) => d.status == DownloadStatus.downloading,
    )) {
      d.status = DownloadStatus.queued;
    }
  }

  final List<Download> items = [];

  /// The download being fetched.
  Download? active;

  /// The active download was removed: its work stops, and it isn't marked failed.
  bool get cancelled => active != null && !items.contains(active);

  /// Whether this episode (its [entry], if any) still needs queueing: never queued, or failed last time.
  static bool needsDownload(Download? d) =>
      d == null || d.status == DownloadStatus.failed;

  /// The download entry (in any state) for this episode and audio.
  Download? entry(Map media, num number, bool dub) => items
      .where(
        (d) =>
            d.media['id'] == media['id'] && d.number == number && d.dub == dub,
      )
      .firstOrNull;

  /// Queues [episodes], skipping ones already queued or saved and retrying failed ones.
  void enqueue(
    Map media,
    String source,
    Iterable<Episode> episodes, {
    required bool dub,
  }) {
    for (final episode in episodes) {
      final existing = entry(media, episode.number, dub);
      if (!needsDownload(existing)) continue;
      // A retry uses the source and episode picked now, not the one that couldn't download it.
      final replacement = Download(
        media: media,
        source: source,
        number: episode.number,
        dub: dub,
        ref: episode.ref,
        title: episode.title,
        thumbnail: episode.thumbnail,
      );
      if (existing == null) {
        items.add(replacement);
      } else {
        items[items.indexOf(existing)] = replacement;
      }
    }
  }

  void retry(Download d) {
    if (!needsDownload(d)) return;
    d
      ..status = DownloadStatus.queued
      ..progress = 0
      ..bytes = 0
      ..error = null;
  }

  /// The next to fetch: the earliest queued.
  Download? get nextQueued =>
      items.where((d) => d.status == DownloadStatus.queued).firstOrNull;

  void markStarted(Download d) {
    active = d;
    d
      ..status = DownloadStatus.downloading
      ..progress = 0
      ..bytes = 0
      ..error = null;
  }

  void markDone(Download d) => d.status = DownloadStatus.done;

  void markFailed(Download d, String error) {
    if (!items.contains(d)) return; // removed while downloading
    d
      ..status = DownloadStatus.failed
      ..error = error;
  }

  /// The active download has stopped, however it ended.
  void finish() => active = null;

  /// Drops [d]; true when it was the active one, whose fetch must stop.
  bool remove(Download d) {
    items.remove(d);
    return identical(active, d);
  }

  /// Drops everything; true when a fetch was running and must stop.
  bool clear() {
    items.clear();
    return active != null;
  }
}

/// The index of downloads on disk (`index.json` in [root]).
class DownloadStore {
  DownloadStore(this.root);
  final Directory root;

  File get _index => File('${root.path}/index.json');

  Future<List<Download>> read() async {
    if (!await _index.exists()) return [];
    try {
      return readIndex(await _index.readAsString());
    } catch (_) {
      return []; // unreadable index: start fresh rather than crash on launch
    }
  }

  /// Written aside and swapped in, so a failed write or closing the app mid-write leaves the old index.
  Future<void> write(String json) async {
    final temp = File('${_index.path}.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename(_index.path);
  }
}

/// Episodes saved on the device. An HLS stream is stored as a local playlist plus its segment, key and subtitle
/// files, so offline playback works exactly like streaming. Downloads run one at a time. Android's foreground
/// service keeps the queue alive; iOS can suspend it when backgrounded. Unfinished segments resume on launch.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  var _queue = DownloadQueue();
  List<Download> get items => _queue.items;
  late Directory _root;

  /// Where the downloaded episodes are kept.
  String get folder => _root.path;
  late DownloadStore _store;
  Completer<void>? _activeDone;
  bool _running = false;
  Future<void> _saving = Future.value();
  static const _notifications = MethodChannel('aniview/downloads');

  var _notifiedPercent = -1;
  var _notifiedAt = DateTime(0);

  /// Documents, or the app's own folder where there isn't one (Linux without xdg-user-dirs throws, and nothing
  /// would start).
  Future<Directory> _appFolder() async {
    try {
      return await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      return getApplicationSupportDirectory();
    }
  }

  Future<Directory> _chosenRoot() async =>
      Platform.isIOS || Settings.desktopDownloadFolder.isEmpty
      ? Directory('${(await _appFolder()).path}/downloads')
      : Directory('${Settings.desktopDownloadFolder}/AniView');

  Future<void> load() async {
    _root = await _chosenRoot();
    await _root.create(recursive: true);
    _store = DownloadStore(_root);
    _queue = DownloadQueue(await _store.read());
    _pump();
  }

  /// Desktop: keeps the downloads in [parent] from now on (the app's own folder when null), taking the ones already
  /// made along. Not while one is being fetched; throws then, or when the folder can't be written.
  Future<void> moveTo(String? parent) async {
    if (items.any(
      (d) =>
          d.status == DownloadStatus.queued ||
          d.status == DownloadStatus.downloading,
    )) {
      throw 'Wait for the current downloads to finish, or cancel them, before moving the folder.';
    }
    final before = _root, chosen = Settings.desktopDownloadFolder;
    Settings.desktopDownloadFolder = parent ?? '';
    final after = await _chosenRoot();
    if (after.path == before.path) return;
    try {
      await after.create(recursive: true);
      for (final entity in await before.list().toList()) {
        final target =
            '${after.path}/${entity.uri.pathSegments.where((s) => s.isNotEmpty).last}';
        try {
          await entity.rename(target);
        } on FileSystemException {
          // Another disk: copy, then remove.
          await _copy(entity, target);
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {
      Settings.desktopDownloadFolder = chosen;
      rethrow;
    }
    _root = after;
    _store = DownloadStore(_root);
    _queue = DownloadQueue(await _store.read());
    notifyListeners();
  }

  Future<void> _copy(FileSystemEntity from, String to) async {
    if (from is File) {
      await from.copy(to);
    } else if (from is Directory) {
      await Directory(to).create(recursive: true);
      await for (final child in from.list()) {
        await _copy(
          child,
          '$to/${child.uri.pathSegments.where((s) => s.isNotEmpty).last}',
        );
      }
    }
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

  /// The download that plays episode [number]: one in the chosen audio while the site can be reached (else the
  /// site streams it), or one in either audio when it can't (something plays rather than nothing).
  Download? toPlay(
    Map media,
    num number, {
    required bool dub,
    required bool online,
  }) => find(media, number, dub: online ? dub : null);

  /// The download entry (in any state) for this episode and audio.
  Download? entry(Map media, num number, bool dub) =>
      _queue.entry(media, number, dub);

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
    final DownloadLocation where = d.storageUri == null
        ? LocalFolder(_dir(d).path)
        : DocumentFolder(d.storageUri!, d.id);
    return VideoStream(
      'Downloaded',
      where.urlOf(d.video ?? 'index.m3u8'),
      const {},
      subtitles: [
        for (final s in d.subtitles) Subtitle(s.label, where.urlOf(s.url)),
      ],
      skips: d.skips,
    );
  }

  /// Queues [episodes] (skipping ones already queued or saved, retrying failed ones) and caches [season] so the
  /// show's full episode list is available offline.
  void enqueue(
    Map media,
    String source,
    Iterable<Episode> episodes, {
    required bool dub,
    required List<Episode> season,
  }) {
    _queue.enqueue(media, source, episodes, dub: dub);
    _notify(save: true);
    _pump();
    saveSeason(media, season);
  }

  /// Retries [d] from the site it came from. The Downloads screens have no other site open; a show page retries
  /// through [enqueue] instead, with the site it has open now.
  void retry(Download d) {
    _queue.retry(d);
    _notify(save: true);
    _pump();
  }

  File _seasonFile(Map media) =>
      File('${_root.path}/seasons/${media['id']}.json');

  /// Caches a show's episode list, only for shows with downloads.
  Future<void> saveSeason(Map media, List<Episode> season) async {
    if (!items.any((d) => d.media['id'] == media['id'])) return;
    try {
      final file = _seasonFile(media);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(season));
      // The cache is optional; offline falls back to the downloaded episodes.
    } catch (_) {}
  }

  /// The cached episode list of a downloaded show, if any.
  Future<List<Episode>?> season(Map media) async {
    try {
      return [
        for (final json
            in jsonDecode(await _seasonFile(media).readAsString()) as List)
          Episode.fromJson(json),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(Download d) async {
    final activeDone = _queue.remove(d) ? _activeDone?.future : null;
    _notify(save: true);
    await activeDone;
    await _deleteGalleryCopy(d);
    try {
      if (d.storageUri case final tree?) {
        await AndroidApp.deleteDownloadFolder(tree, d.id);
      } else {
        await _dir(d).delete(recursive: true);
      }
    } catch (_) {} // nothing on disk yet
    if (!items.any((i) => i.media['id'] == d.media['id'])) {
      _seasonFile(d.media).delete().ignore();
    }
  }

  Future<void> _deleteGalleryCopy(Download d) async {
    if (d.galleryUri case final uri?) {
      try {
        await AndroidApp.deleteFromGallery(uri);
      } catch (_) {} // gone already, or no longer ours (a reinstall)
    }
  }

  Future<void> removeAll() async {
    final removed = [...items];
    final activeDone = _queue.clear() ? _activeDone?.future : null;
    _notify(save: true);
    await activeDone;
    for (final d in removed) {
      await _deleteGalleryCopy(d);
      if (d.storageUri case final tree?) {
        try {
          await AndroidApp.deleteDownloadFolder(tree, d.id);
        } catch (_) {}
      }
    }
    for (final entity in await _root.list().toList()) {
      if (entity is Directory) await entity.delete(recursive: true);
    }
  }

  /// System notification for the running download, throttled because Android drops rapid updates.
  void _notifyProgress() {
    final d = _queue.active;
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
        await _store.write(json);
      } catch (_) {}
    });
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = _queue.nextQueued;
        if (next == null) break;
        await _download(next);
      }
    } finally {
      _running = false;
      // Lets the app be backgrounded normally again (see DownloadService.kt).
      _notifications.invokeMethod('idle').catchError((Object _) => null);
    }
  }

  Future<void> _download(Download d) async {
    final done = _activeDone = Completer<void>();
    String? note; // shown in the finished notification
    _notifiedPercent = -1;
    _queue.markStarted(d);
    _notify(save: true);
    try {
      // No handler: a download runs with nothing on screen to show a check on.
      final listing =
          await SiteListing.of(d.source, d.media) ??
          (throw Exception('${d.source} is no longer one of the top sites'));
      final streams = await listing.streams(d.episode, dub: d.dub);
      if (streams.isEmpty) {
        throw Exception('No ${d.dub ? 'dub' : 'sub'} servers for this episode');
      }
      // HLS first (sites), else a single file (often an extension's). Audio served as a file of its own isn't saved,
      // so those servers are passed over rather than saved silent.
      final stream =
          streams.where((s) => s.isHls && s.audios.isEmpty).firstOrNull ??
          streams.where((s) => s.audios.isEmpty).firstOrNull ??
          (throw Exception('No downloadable servers for this episode'));
      final dir = await _dir(d).create(recursive: true);
      var length = Duration.zero; // AniSkip takes any length for a single file
      // An extension's playlist may sit at an address without .m3u8: the file it sends says so.
      final whole = !stream.isHls && await _saveFile(d, stream, dir);
      if (!whole) {
        length = await _saveHls(
          d,
          stream.isHls ? stream : stream.asPlaylist,
          dir,
        );
      }
      d.subtitles = await _saveSubtitles(stream, dir);
      if (!whole) note = await _toMp4(d, dir);
      note ??= await _embedSubtitles(d, dir);
      final community = await aniSkip(d.media['idMal'], d.number, length);
      d
        ..skips = community.isNotEmpty ? community : stream.skips
        ..progress = 1;
      // The folder is part of saving to the gallery; without it, episodes stay in app storage.
      if (Platform.isAndroid &&
          Settings.saveToGallery &&
          Settings.downloadFolder.isNotEmpty) {
        await AndroidApp.exportDownloadFolder(
          Settings.downloadFolder,
          d.id,
          dir.path,
        );
        d.storageUri = Settings.downloadFolder;
      }
      _queue.markDone(d);
      if (Platform.isAndroid && Settings.saveToGallery && d.video != null) {
        note = await _saveToGallery(d, dir);
      }
      if (d.storageUri != null) await dir.delete(recursive: true);
    } catch (e) {
      _queue.markFailed(
        d,
        e is CloudflareChallenge
            ? '${d.source} needs a quick verification: play any episode from it once, then retry'
            : friendlyError(e),
      );
    } finally {
      final cancelled = _queue.cancelled;
      _post(cancelled ? 'cancel' : d.status.name, d, {'text': d.error ?? note});
      _queue.finish();
      _activeDone = null;
      if (!cancelled) _notify(save: true);
      done.complete();
    }
  }

  /// Joins the saved segments into one MP4 (no re-encoding) and drops them; returns why it couldn't, or null. An
  /// episode that couldn't be joined stays an HLS playlist, which still plays.
  Future<String?> _toMp4(Download d, Directory dir) async {
    // iOS cannot launch an ffmpeg executable. Its native player opens the saved playlist directly.
    if (Platform.isIOS) return null;
    final video = '${d.name}.mp4';
    final out = '${dir.path}/$video';
    try {
      if (Platform.isAndroid) {
        await AndroidApp.toMp4(dir.path, out);
      } else {
        // ponytail: desktop leans on the system's ffmpeg; without one on PATH the episode stays HLS. Bundle an
        // ffmpeg (or a Dart TS-to-MP4 remuxer) if that's common on Windows/macOS.
        final run = await Process.run('ffmpeg', [
          '-y', '-v', 'error', '-allowed_extensions', 'ALL', //
          '-i', 'index.m3u8', '-map', '0:v?', '-map', '0:a?', //
          '-c', 'copy', '-movflags', '+faststart', './$video',
        ], workingDirectory: dir.path);
        if (run.exitCode != 0) throw Exception('${run.stderr}'.trim());
      }
    } on ProcessException {
      return 'Downloaded · kept as HLS: install ffmpeg to save MP4s';
    } catch (e) {
      if (await File(out).exists()) await File(out).delete();
      return 'Downloaded · not saved as MP4: ${e is PlatformException ? e.message : e}';
    }
    final keep = {video, for (final s in d.subtitles) s.url};
    for (final file in await dir.list().toList()) {
      if (!keep.contains(file.uri.pathSegments.last)) {
        await file.delete(recursive: true);
      }
    }
    d
      ..video = video
      ..bytes = await File(out).length();
    return null;
  }

  /// Copies a finished episode's MP4 to the gallery; returns why it couldn't, or null.
  Future<String?> _saveToGallery(Download d, Directory dir) async {
    try {
      d.galleryUri = await AndroidApp.saveToGallery(
        '${dir.path}/${d.video}',
        d.name,
      );
      return 'Downloaded · saved to gallery';
    } on PlatformException catch (e) {
      return 'Downloaded · not saved to gallery: ${e.message}';
    } on MissingPluginException {
      return null; // not on Android
    }
  }

  /// Saves a server that's one whole file (an MP4) as the episode's video, resuming a part saved before. False,
  /// with nothing saved, when what it sends is an HLS playlist after all.
  Future<bool> _saveFile(Download d, VideoStream stream, Directory dir) async {
    // A part saved from another source is other video.
    await prepareHlsFiles(dir, '${d.source}\n${d.ref}');
    final video = '${d.name}.mp4';
    final part = File('${dir.path}/$video.part');
    var have = await part.exists() ? await part.length() : 0;
    final response = await openGet(
      stream.url,
      headers: {...stream.headers, if (have > 0) 'Range': 'bytes=$have-'},
    );
    if (response.statusCode == 200) {
      have = 0; // the host ignored the range: start over
    } else if (response.statusCode != 206) {
      await response.stream.drain<void>();
      throw HttpException(
        'HTTP ${response.statusCode}',
        uri: Uri.parse(stream.url),
      );
    }
    final total = response.contentLength == null
        ? null
        : have + response.contentLength!;
    final sink = part.openWrite(
      mode: have > 0 ? FileMode.append : FileMode.write,
    );
    var shown = -1;
    try {
      await for (final chunk in response.stream) {
        if (_queue.cancelled) throw _Cancelled();
        if (have == 0 && isPlaylist(chunk)) {
          await sink.close();
          await part.delete();
          return false;
        }
        sink.add(chunk);
        have += chunk.length;
        d.bytes = have;
        // ponytail: no total (chunked replies) leaves the bar at 0 until done
        if (total != null && total > 0) d.progress = have / total;
        // A chunk is a few KB: the screen and notification hear of every 0.2% instead.
        if ((d.progress * 500).floor() != shown) {
          shown = (d.progress * 500).floor();
          _notify();
        }
      }
    } finally {
      await sink.close();
    }
    if (total != null && have < total) {
      throw const HttpException('The download was cut short');
    }
    if (!isVideoFile(await _head(part))) {
      await part.delete();
      throw Exception("This server didn't send a video");
    }
    await part.rename('${dir.path}/$video');
    d.video = video;
    return true;
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
      // ponytail: audio in a rendition of its own isn't saved, so it's refused rather than saved silent; save the
      // default rendition beside the variant, under a local master playlist, if a site needs it
      if (RegExp(r'#EXT-X-MEDIA:[^\n]*TYPE=AUDIO[^\n]*URI=')
          .hasMatch(playlist)) {
        throw Exception("Downloads from this site aren't supported yet");
      }
      url = url.resolve(
        bestVariant(playlist, maxHeight: Settings.downloadQuality),
      );
      playlist = await fetch('$url', headers: stream.headers);
    }
    final (local, files, length) = localizePlaylist(playlist, url);
    await prepareHlsFiles(dir, '${d.source}\n${d.ref}');
    final queue = files.entries.toList().iterator;
    var done = 0;
    var stop = false;

    Future<void> worker() async {
      try {
        while (!stop && queue.moveNext()) {
          final MapEntry(key: name, value: remote) = queue.current;
          if (_queue.cancelled) throw _Cancelled();
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
    // The language picked in Settings and English, however a site or extension names them ("en-US", "eng").
    final wanted = {languageCode(Settings.subtitleLanguage), 'eng'}
      ..remove('und');
    final saved = <Subtitle>[];
    for (final subtitle in stream.subtitles.where(
      (s) =>
          wanted.contains(languageCode(s.label)) ||
          s.label.startsWith(Settings.subtitleLanguage),
    )) {
      try {
        final bytes = await _fetchWithRetry(subtitle.url, stream.headers);
        // Saved as what it is (an extension's .ass stays .ass), so players read it as such.
        final name =
            'sub${saved.length}.${subtitleExtOf(subtitle.url) ?? sniffSubtitle(bytes)}';
        await File('${dir.path}/$name').writeAsBytes(bytes);
        saved.add(Subtitle(subtitle.label, name));
      } catch (_) {} // subtitles are optional for offline playback
    }
    return saved;
  }

  /// Puts the saved subtitles inside the episode's MP4 too, as plain text, so it carries them to any player; the
  /// files stay beside it for ours, with their styling. Returns why it couldn't, or null.
  Future<String?> _embedSubtitles(Download d, Directory dir) async {
    if (d.video == null || d.subtitles.isEmpty) return null;
    try {
      await embedSubtitles('${dir.path}/${d.video}', [
        for (final s in d.subtitles)
          (
            s.label,
            parseCues(
              await File('${dir.path}/${s.url}').readAsString(),
              s.url.split('.').last,
            ),
          ),
      ]);
      d.bytes = await File('${dir.path}/${d.video}').length();
      return null;
    } catch (e) {
      return 'Downloaded · subtitles not added to the MP4: $e';
    }
  }
}

/// Whether the start of a download is an HLS playlist rather than video.
@visibleForTesting
bool isPlaylist(List<int> head) => utf8
    .decode(head.take(64).toList(), allowMalformed: true)
    .replaceFirst('\uFEFF', '')
    .trimLeft()
    .startsWith('#EXTM3U');

/// Whether a file starts like a video players open: MP4/MOV, Matroska/WebM, MPEG-TS, AVI or FLV.
@visibleForTesting
bool isVideoFile(List<int> head) {
  bool at(int i, List<int> bytes) =>
      head.length >= i + bytes.length &&
      [for (var j = 0; j < bytes.length; j++) head[i + j]].join() ==
          bytes.join();
  return at(4, 'ftyp'.codeUnits) ||
      at(0, [0x1A, 0x45, 0xDF, 0xA3]) ||
      at(0, [0x47]) ||
      at(0, 'RIFF'.codeUnits) ||
      at(0, 'FLV'.codeUnits);
}

Future<List<int>> _head(File file) async {
  final raf = await file.open();
  try {
    return await raf.read(16);
  } finally {
    await raf.close();
  }
}

/// Partial segments are reused only when they came from the same source's episode: another source names its files
/// the same but they hold different video. (Not the segment addresses: those often carry a token that expires.)
@visibleForTesting
Future<void> prepareHlsFiles(Directory dir, String origin) async {
  final mark = File('${dir.path}/origin');
  if (await mark.exists() && await mark.readAsString() == origin) return;
  for (final file in await dir.list().toList()) {
    await file.delete(recursive: true);
  }
  await mark.writeAsString(origin, flush: true);
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

/// URI of the highest-bandwidth variant in a master playlist no taller than [maxHeight] (0 = any). When every
/// variant is taller, the smallest one.
String bestVariant(String master, {int maxHeight = 0}) {
  final lines = master.split('\n').map((l) => l.trim()).toList();
  final variants = <(int bandwidth, int height, String uri)>[];
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    int attribute(String pattern) =>
        int.tryParse(RegExp(pattern).firstMatch(lines[i])?[1] ?? '') ?? 0;
    final uri = lines
        .skip(i + 1)
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    if (uri.isNotEmpty) {
      variants.add((
        attribute(r'BANDWIDTH=(\d+)'),
        attribute(r'RESOLUTION=\d+x(\d+)'),
        uri,
      ));
    }
  }
  if (variants.isEmpty) {
    throw const FormatException('The stream has no playable variant');
  }
  variants.sort((a, b) => b.$1.compareTo(a.$1)); // best first
  return (variants
              .where((v) => maxHeight == 0 || v.$2 <= maxHeight)
              .firstOrNull ??
          variants.last)
      .$3;
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
