import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import 'platform.dart';

/// A subtitle track the stream or a subtitle file brings; [id] picks it in [ExoPlayer.setSubtitleTrack].
class SubtitleTrack {
  const SubtitleTrack(this.id, {this.title, this.language});

  /// Whatever the stream marks as its default (or none).
  static const auto = SubtitleTrack('auto');
  static const off = SubtitleTrack('off');

  final String id;
  final String? title, language;

  @override
  bool operator ==(Object other) => other is SubtitleTrack && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A subtitle file to load alongside the video: it shows up in [ExoPlayerState.subtitles] titled [label].
typedef SubtitleFile = ({String url, String label});

class ExoPlayerState {
  Duration position = Duration.zero,
      duration = Duration.zero,
      buffer = Duration.zero;
  bool playing = false, buffering = true, completed = false;
  List<SubtitleTrack> subtitles = const [];

  /// The stream's video heights (1080, 720, …), tallest first.
  List<int> heights = const [];

  /// The picture's size once known.
  Size? size;
}

/// Media3 ExoPlayer on the Android side (see ExoPlayers.kt), drawing into a texture; libmpv through media_kit on
/// desktop. Reads like media_kit's player: [state] for now, [stream] for changes.
class ExoPlayer {
  ExoPlayer() {
    if (!Platform.isAndroid) {
      _ready = Future.value();
      _startMpv();
      return;
    }
    _ready = _channel.invokeMapMethod<String, Object>('create').then((ids) {
      _id = (ids!['id']! as num).toInt();
      texture.value = (ids['texture']! as num).toInt();
      _events = EventChannel('aniview/exo/$_id')
          .receiveBroadcastStream()
          .listen((e) => _on(e as Map));
    });
  }

  static const _channel = MethodChannel('aniview/exo');
  late final Future<void> _ready;
  int? _id;
  StreamSubscription? _events;
  bool _disposed = false;
  mk.Player? _mpv;

  /// The desktop picture's controller; null on Android, which draws [texture].
  VideoController? video;

  /// The texture the picture draws into, once the player exists.
  final texture = ValueNotifier<int?>(null);

  /// The subtitle text showing now, empty for none.
  final cues = ValueNotifier<String>('');

  final state = ExoPlayerState();
  final stream = ExoPlayerStreams._();

  void _on(Map e) {
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
    if (e['tracks'] case final List tracks) {
      state.subtitles = [
        for (final t in tracks.cast<Map>())
          SubtitleTrack(
            t['id'] as String,
            title: t['title'] as String?,
            language: t['language'] as String?,
          ),
      ];
      stream._tracks.add(state.subtitles);
    }
    if (e['cues'] case final String text) cues.value = text;
    if (e['error'] case final String error) stream._error.add(error);
  }

  Future<void> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    await _ready;
    if (_disposed) return;
    if (_mpv case final mpv?) return _mpvCall(mpv, method, args);
    await _channel.invokeMethod(method, {'id': _id, ...args});
  }

  // One mpv for the app's whole run, stopped between videos: a new instance after another has shut down can abort
  // inside libmpv (m_config_core.c "group_index >= 0") as it opens its first file.
  static mk.Player? _sharedMpv;
  static VideoController? _sharedVideo;

  void _startMpv() {
    final mpv = _mpv = _sharedMpv ??= mk.Player();
    video = _sharedVideo ??= VideoController(mpv);
    final s = mpv.stream;
    // Each [_on] key is read on its own, so the position event carries what it needs.
    void position(Duration _) => _on({
      'position': mpv.state.position.inMilliseconds,
      'buffer': mpv.state.buffer.inMilliseconds,
      'duration': mpv.state.duration.inMilliseconds,
    });
    _mpvEvents = [
      s.position.listen(position),
      s.duration.listen(position),
      s.playing.listen((v) => _on({'playing': v})),
      s.buffering.listen((v) => _on({'buffering': v})),
      s.completed.listen((v) => _on({'completed': v})),
      s.error.listen((e) => _on({'error': e})),
      s.subtitle.listen((lines) => _on({'cues': lines.join('\n').trim()})),
      s.tracks.listen(
        (t) => _on({
          'tracks': [
            for (final t in t.subtitle)
              if (t.id != 'auto' && t.id != 'no')
                {'id': t.id, 'title': t.title, 'language': t.language},
          ],
        }),
      ),
      s.width.listen((_) => _mpvSize(mpv)),
      s.height.listen((_) => _mpvSize(mpv)),
    ];
  }

  late List<StreamSubscription> _mpvEvents;

  void _mpvSize(mk.Player mpv) {
    if (mpv.state.width case final w? when w > 0) {
      if (mpv.state.height case final h? when h > 0) {
        _on({'width': w, 'height': h});
      }
    }
  }

  Future<void> _mpvCall(
    mk.Player mpv,
    String method,
    Map<String, Object?> args,
  ) async {
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
        if (subtitles.isEmpty) return;
        // A subtitle file can only join once the stream has loaded.
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
      // 'quality': mpv takes the stream's own pick, there's no cap to set yet.
    }
  }

  /// Plays [url] from [start]: a local file path, or a URL fetched with [headers]. [hls] says it's a playlist
  /// when the URL doesn't. [subtitles] load alongside, offered as tracks.
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    bool hls = false,
    Duration? start,
    List<SubtitleFile> subtitles = const [],
  }) {
    state
      ..position = start ?? Duration.zero
      ..duration = Duration.zero
      ..completed = false
      ..buffering = true
      ..subtitles = const [];
    cues.value = '';
    return _call('open', {
      'url': url,
      'headers': headers ?? const {},
      'hls': hls,
      'start': start?.inMilliseconds ?? 0,
      'subtitles': [
        for (final s in subtitles) {'url': s.url, 'label': s.label},
      ],
    });
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

  /// The player's own volume, 0–1 (Android moves the phone's media volume instead).
  Future<void> setVolume(double level) => _mpv == null
      ? AndroidApp.setVolume(level)
      : _call('volume', {'level': level});

  Future<void> dispose() async {
    if (_mpv case final mpv?) {
      _disposed = true;
      for (final sub in _mpvEvents) {
        sub.cancel();
      }
      await mpv.stop();
      await mpv.setVolume(100);
    } else {
      await _call('dispose');
      _disposed = true;
    }
    await _events?.cancel();
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
