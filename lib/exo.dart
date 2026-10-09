import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import 'platform.dart';

/// A subtitle or audio track the stream or a file beside it brings; [id] picks it in [ExoPlayer.setSubtitleTrack]
/// or [ExoPlayer.setAudioTrack].
class SubtitleTrack {
  const SubtitleTrack(this.id, {this.title, this.language});

  /// Whatever the stream marks as its default (or none).
  static const auto = SubtitleTrack('auto');
  static const off = SubtitleTrack('off');

  final String id;
  final String? title, language;

  /// What the person reads for it.
  String get name => title ?? language ?? 'Track $id';

  @override
  bool operator ==(Object other) => other is SubtitleTrack && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A subtitle or audio file to load alongside the video: it shows up in [ExoPlayerState.subtitles] or
/// [ExoPlayerState.audios] titled [label].
typedef SubtitleFile = ({String url, String label});

class ExoPlayerState {
  Duration position = Duration.zero,
      duration = Duration.zero,
      buffer = Duration.zero;
  bool playing = false, buffering = true, completed = false;
  List<SubtitleTrack> subtitles = const [], audios = const [];

  /// The stream's video heights (1080, 720, …), tallest first.
  List<int> heights = const [];

  /// The picture's size once known.
  Size? size;
}

/// Where [ExoPlayer]'s commands go and its events come from: Media3 ExoPlayer on the Android side (see
/// ExoPlayers.kt) over a channel, libmpv through media_kit on desktop, or a fake in tests. Commands are the
/// channel's (`open`, `seek`, `subtitle`, …); events are maps of what changed (`position`, `tracks`, …).
abstract class PlayerBackend {
  /// Creates the player; [on] gets every event from then on.
  Future<void> start(void Function(Map event) on);
  Future<void> call(String method, Map<String, Object?> args);

  /// The player's own volume, 0–1.
  Future<void> setVolume(double level);
  Future<void> dispose();

  /// The desktop picture's controller; null where the picture is a texture.
  VideoController? get video => null;
}

/// Android: the player lives in ExoPlayers.kt and draws into a texture, announced as a `texture` event.
class _AndroidBackend extends PlayerBackend {
  static const _channel = MethodChannel('aniview/exo');
  int? _id;
  StreamSubscription? _events;

  @override
  Future<void> start(void Function(Map event) on) async {
    final ids = await _channel.invokeMapMethod<String, Object>('create');
    _id = (ids!['id']! as num).toInt();
    on({'texture': (ids['texture']! as num).toInt()});
    _events = EventChannel('aniview/exo/$_id')
        .receiveBroadcastStream()
        .listen((e) => on(e as Map));
  }

  @override
  Future<void> call(String method, Map<String, Object?> args) =>
      _channel.invokeMethod(method, {'id': _id, ...args});

  /// Moves the phone's media volume; the player has none of its own.
  @override
  Future<void> setVolume(double level) => AndroidApp.setVolume(level);

  @override
  Future<void> dispose() async {
    await call('dispose', const {});
    await _events?.cancel();
  }
}

/// Desktop: libmpv, answering the Android channel's commands and events.
class _MpvBackend extends PlayerBackend {
  // One mpv for the app's whole run, stopped between videos: a new instance after another has shut down can abort
  // inside libmpv (m_config_core.c "group_index >= 0") as it opens its first file.
  static mk.Player? _sharedMpv;
  static VideoController? _sharedVideo;

  final mk.Player _mpv = _sharedMpv ??= mk.Player();
  bool _disposed = false;

  @override
  VideoController? video;

  @override
  Future<void> start(void Function(Map event) on) async {
    final mpv = _mpv;
    video = _sharedVideo ??= VideoController(mpv);
    final s = mpv.stream;
    // Each event key is read on its own, so the position event carries what it needs.
    void position(Duration _) => on({
      'position': mpv.state.position.inMilliseconds,
      'buffer': mpv.state.buffer.inMilliseconds,
      'duration': mpv.state.duration.inMilliseconds,
    });
    _events = [
      s.position.listen(position),
      s.duration.listen(position),
      s.playing.listen((v) => on({'playing': v})),
      s.buffering.listen((v) => on({'buffering': v})),
      s.completed.listen((v) => on({'completed': v})),
      s.error.listen((e) => on({'error': e})),
      s.subtitle.listen((lines) => on({'cues': lines.join('\n').trim()})),
      s.tracks.listen(
        (t) => on({
          'audios': [
            for (final t in t.audio)
              if (t.id != 'auto' && t.id != 'no')
                {'id': t.id, 'title': t.title, 'language': t.language},
          ],
          'tracks': [
            for (final t in t.subtitle)
              if (t.id != 'auto' && t.id != 'no')
                {'id': t.id, 'title': t.title, 'language': t.language},
          ],
        }),
      ),
      s.width.listen((_) => _size(mpv, on)),
      s.height.listen((_) => _size(mpv, on)),
    ];
  }

  late List<StreamSubscription> _events;

  void _size(mk.Player mpv, void Function(Map event) on) {
    if (mpv.state.width case final w? when w > 0) {
      if (mpv.state.height case final h? when h > 0) {
        on({'width': w, 'height': h});
      }
    }
  }

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    final mpv = _mpv;
    switch (method) {
      case 'open':
        await mpv.open(
          mk.Media(
            args['url']! as String,
            httpHeaders: (args['headers']! as Map).cast<String, String>(),
            start: Duration(milliseconds: args['start']! as int),
          ),
        );
        final subtitles = args['subtitles']! as List;
        final audios = args['audios']! as List;
        if (subtitles.isEmpty && audios.isEmpty) return;
        // A subtitle or audio file can only join once the stream has loaded.
        final loaded = await mpv.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () => Duration.zero,
            );
        if (loaded == Duration.zero) return;
        for (final Map s in subtitles) {
          // Closed meanwhile: the shared player has moved on to another video.
          if (_disposed) return;
          await (mpv.platform as mk.NativePlayer).command([
            'sub-add',
            s['url'] as String,
            'auto',
            s['label'] as String,
          ]);
        }
        for (final Map a in audios) {
          if (_disposed) return;
          await (mpv.platform as mk.NativePlayer).command([
            'audio-add',
            a['url'] as String,
            // The first plays, as the stream's own would; the rest wait to be picked.
            a == audios.first ? 'select' : 'auto',
            a['label'] as String,
          ]);
        }
      case 'stop':
        await mpv.stop();
      case 'play':
        await mpv.play();
      case 'pause':
        await mpv.pause();
      case 'seek':
        await mpv.seek(Duration(milliseconds: args['ms']! as int));
      case 'rate':
        await mpv.setRate(args['rate']! as double);
      case 'volume':
        await mpv.setVolume((args['level']! as double) * 100);
      case 'subtitle':
        await mpv.setSubtitleTrack(switch (args['track']) {
          'off' => mk.SubtitleTrack.no(),
          'auto' => mk.SubtitleTrack.auto(),
          final id => mpv.state.tracks.subtitle.firstWhere((t) => t.id == id),
        });
      case 'audio':
        await mpv.setAudioTrack(switch (args['track']) {
          'auto' => mk.AudioTrack.auto(),
          final id => mpv.state.tracks.audio.firstWhere((t) => t.id == id),
        });
      // 'quality': mpv takes the stream's own pick, there's no cap to set yet.
    }
  }

  @override
  Future<void> setVolume(double level) => call('volume', {'level': level});

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _events) {
      sub.cancel();
    }
    await _mpv.stop();
    await _mpv.setVolume(100);
  }
}

/// The video player: Media3 ExoPlayer on Android, drawing into a texture; libmpv on desktop (see [PlayerBackend]).
/// Reads like media_kit's player: [state] for now, [stream] for changes.
class ExoPlayer {
  ExoPlayer([PlayerBackend? backend])
    : _backend =
          backend ?? (Platform.isAndroid ? _AndroidBackend() : _MpvBackend()) {
    _ready = _backend.start(_on);
  }

  final PlayerBackend _backend;
  late final Future<void> _ready;
  bool _disposed = false;

  /// Counts [load]s, so one overtaken by the next stops settling.
  int _loads = 0;

  /// The desktop picture's controller; null on Android, which draws [texture].
  VideoController? get video => _backend.video;

  /// The texture the picture draws into, once the player exists.
  final texture = ValueNotifier<int?>(null);

  /// The subtitle text showing now, empty for none.
  final cues = ValueNotifier<String>('');

  final state = ExoPlayerState();
  final stream = ExoPlayerStreams._();

  void _on(Map e) {
    if (e['texture'] case final int id) texture.value = id;
    Duration ms(Object? v) => Duration(milliseconds: (v as num).toInt());
    if (e['position'] != null) {
      state.position = ms(e['position']);
      state.buffer = ms(e['buffer']);
      stream._position.add(state.position);
      final duration = ms(e['duration']);
      if (duration != state.duration) {
        state.duration = duration;
        stream._duration.add(duration);
      }
    }
    if (e['playing'] case final bool playing when playing != state.playing) {
      state.playing = playing;
      stream._playing.add(playing);
    }
    if (e['buffering'] case final bool buffering) {
      state.buffering = buffering;
      stream._buffering.add(buffering);
    }
    if (e['completed'] case final bool completed
        when completed != state.completed) {
      state.completed = completed;
      stream._completed.add(completed);
    }
    if (e['width'] case final num width) {
      state.size = Size(width.toDouble(), (e['height'] as num).toDouble());
      stream._size.add(state.size!);
    }
    if (e['heights'] case final List heights) {
      state.heights = heights.cast<int>();
    }
    // Before the tracks: their event tells the player to look at both.
    if (e['audios'] case final List audios) state.audios = _tracks(audios);
    if (e['tracks'] case final List tracks) {
      state.subtitles = _tracks(tracks);
      stream._tracks.add(state.subtitles);
    }
    if (e['cues'] case final String text) cues.value = text;
    if (e['error'] case final String error) stream._error.add(error);
  }

  static List<SubtitleTrack> _tracks(List tracks) => [
    for (final t in tracks.cast<Map>())
      SubtitleTrack(
        t['id'] as String,
        title: t['title'] as String?,
        language: t['language'] as String?,
      ),
  ];

  Future<void> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    await _ready;
    if (_disposed) return;
    await _backend.call(method, args);
  }

  /// Plays [url] from [start]: a local file path, or a URL fetched with [headers]. [hls] says it's a playlist
  /// when the URL doesn't. [subtitles] and [audios] (audio that comes as files of its own) load alongside, offered
  /// as tracks.
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    bool hls = false,
    Duration? start,
    List<SubtitleFile> subtitles = const [],
    List<SubtitleFile> audios = const [],
  }) {
    state
      ..position = start ?? Duration.zero
      ..duration = Duration.zero
      ..completed = false
      ..buffering = true
      ..subtitles = const []
      ..audios = const [];
    cues.value = '';
    return _call('open', {
      'url': url,
      'headers': headers ?? const {},
      'hls': hls,
      'start': start?.inMilliseconds ?? 0,
      'subtitles': [
        for (final s in subtitles) {'url': s.url, 'label': s.label},
      ],
      'audios': [
        for (final a in audios) {'url': a.url, 'label': a.label},
      ],
    });
  }

  /// [open]s [url] and settles it once it has loaded: lands on [start] when the stream ignored it, shows the
  /// subtitles (none when [subtitlesOff], else the file labelled [subtitleFile] when its track shows up, else the
  /// stream's own), picks the audio track [named] [audio] when there is one, and plays at [rate]. Completes with the
  /// subtitles' label ('Off', the file's, or 'Auto'), or null when a later [load] or [dispose] overtook it.
  Future<String?> load(
    String url, {
    Map<String, String>? headers,
    bool hls = false,
    Duration? start,
    List<SubtitleFile> subtitles = const [],
    List<SubtitleFile> audios = const [],
    bool subtitlesOff = false,
    String? subtitleFile,
    String? audio,
    double rate = 1,
  }) async {
    final ticket = ++_loads;
    bool overtaken() => _disposed || ticket != _loads;
    final resume = start != null && start > Duration.zero ? start : null;
    await open(
      url,
      headers: headers,
      hls: hls,
      start: resume,
      subtitles: subtitles,
      audios: audios,
    );
    // open() returns before the stream has loaded, and picking a track before that is dropped.
    if (state.duration == Duration.zero) {
      await stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 20), onTimeout: () => Duration.zero);
    }
    if (overtaken()) return null;
    // Some streams ignore the start position; land there anyway.
    if (resume != null &&
        state.position < resume - const Duration(seconds: 3)) {
      await seek(resume);
    }
    final String shown;
    if (subtitlesOff) {
      await setSubtitleTrack(SubtitleTrack.off);
      shown = 'Off';
    } else if (subtitleFile != null && await showSubtitleFile(subtitleFile)) {
      shown = subtitleFile;
    } else {
      await setSubtitleTrack(SubtitleTrack.auto); // embedded or burned-in subs
      shown = 'Auto';
    }
    if (overtaken()) return null;
    if (state.audios.where((t) => t.name == audio).firstOrNull
        case final track?) {
      await setAudioTrack(track);
    }
    await setRate(rate);
    return overtaken() ? null : shown;
  }

  /// Shows the subtitle file loaded with the stream (see [open]) as [label], once its track shows up; false when
  /// it doesn't.
  Future<bool> showSubtitleFile(String label) async {
    bool isIt(SubtitleTrack t) => t.title == label;
    final track =
        state.subtitles.where(isIt).firstOrNull ??
        await stream.tracks
            .map((tracks) => tracks.where(isIt).firstOrNull)
            .firstWhere((t) => t != null)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
    if (track == null || _disposed) return false;
    await setSubtitleTrack(track);
    return true;
  }

  /// Stops and unloads the video, so nothing more is reported until the next [open].
  Future<void> stop() {
    state
      ..position = Duration.zero
      ..duration = Duration.zero
      ..playing = false;
    cues.value = '';
    return _call('stop');
  }

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');
  Future<void> playOrPause() => state.playing ? pause() : play();

  Future<void> seek(Duration to) {
    state.position = to;
    return _call('seek', {'ms': to.inMilliseconds});
  }

  Future<void> setRate(double rate) => _call('rate', {'rate': rate});

  /// Caps the picture at [height] lines (0: no cap); [exact] keeps it there on a slow connection.
  Future<void> setQuality(int height, {bool exact = false}) =>
      _call('quality', {'height': height, 'exact': exact});

  Future<void> setSubtitleTrack(SubtitleTrack track) {
    if (track == SubtitleTrack.off) cues.value = '';
    return _call('subtitle', {'track': track.id});
  }

  Future<void> setAudioTrack(SubtitleTrack track) =>
      _call('audio', {'track': track.id});

  /// The player's own volume, 0–1 (Android moves the phone's media volume instead).
  Future<void> setVolume(double level) async {
    await _ready;
    if (!_disposed) await _backend.setVolume(level);
  }

  Future<void> dispose() async {
    await _ready;
    _disposed = true;
    await _backend.dispose();
    stream._close();
    texture.dispose();
    cues.dispose();
  }
}

class ExoPlayerStreams {
  ExoPlayerStreams._();

  final _position = StreamController<Duration>.broadcast(),
      _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast(),
      _buffering = StreamController<bool>.broadcast(),
      _completed = StreamController<bool>.broadcast();
  final _tracks = StreamController<List<SubtitleTrack>>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _size = StreamController<Size>.broadcast();

  Stream<Duration> get position => _position.stream;
  Stream<Duration> get duration => _duration.stream;
  Stream<bool> get playing => _playing.stream;
  Stream<bool> get buffering => _buffering.stream;
  Stream<bool> get completed => _completed.stream;
  Stream<List<SubtitleTrack>> get tracks => _tracks.stream;
  Stream<String> get error => _error.stream;
  Stream<Size> get size => _size.stream;

  void _close() {
    for (final c in [
      _position,
      _duration,
      _playing,
      _buffering,
      _completed,
      _tracks,
      _error,
      _size,
    ]) {
      c.close();
    }
  }
}

/// The picture, fitted to the space by [fit], with the subtitles drawn over it in [subtitleStyle].
class ExoVideo extends StatelessWidget {
  const ExoVideo(
    this.player, {
    super.key,
    this.fit = BoxFit.contain,
    required this.subtitleStyle,
  });

  final ExoPlayer player;
  final BoxFit fit;
  final TextStyle subtitleStyle;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (player.video case final video?)
          Video(
            controller: video,
            fit: fit,
            controls: NoVideoControls,
            fill: Colors.black,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              visible: false,
            ),
          )
        else
          ValueListenableBuilder(
            valueListenable: player.texture,
            builder: (context, texture, _) => texture == null
                ? const SizedBox.expand()
                : StreamBuilder(
                    stream: player.stream.size,
                    initialData: player.state.size,
                    builder: (context, snap) {
                      final size = snap.data;
                      if (size == null) return const SizedBox.expand();
                      return ClipRect(
                        child: FittedBox(
                          fit: fit,
                          child: SizedBox(
                            width: size.width,
                            height: size.height,
                            child: Texture(
                              textureId: texture,
                              filterQuality: FilterQuality.low,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 32,
          child: ValueListenableBuilder(
            valueListenable: player.cues,
            builder: (context, text, _) =>
                Text(text, textAlign: TextAlign.center, style: subtitleStyle),
          ),
        ),
      ],
    ),
  );
}
