part of '../player.dart';

/// Anime4K upscaling in the player: the [Upscaler] that keeps mpv's shaders matched to the window, its choice beside
/// the speed's, and, on Android, which player a session gets.
///
/// iOS and desktop always play through mpv. Android plays through Media3, and through mpv only when upscaling is on
/// as the player opens; it keeps that backend for the player's life. So on Android, turning upscaling on or off
/// applies from the next video, while Fast and Quality (and Off, which clears the shaders) apply at once on mpv.
extension _Upscaling on _PlayerScreenState {
  /// Upscaling as saved, as the player opens: on Android it picks mpv over Media3.
  bool get _upscaleOnOpen => Settings.upscale != Upscale.off;

  /// The player plays through mpv: it sends HLS through the relay's single variant and its errors before load are
  /// log lines as often as failures (see [PlaybackSession.onError]). Media3 on Android unless upscaling.
  bool get _onMpv => player.backend == VideoBackend.mediaKit;

  /// Android TV boxes get Off and Fast only (see [upscaleTiers]).
  bool get _upscaleTv => playsOnAndroid && deviceIsTv;

  /// Phones and TV boxes get the short chains.
  bool get _mobileUpscaling => playsOnAndroid || playbackOs == 'ios';

  /// Whether the player offers the choice: wherever mpv plays, and on Android always, to pick for the next video.
  bool get _offersUpscaling => _upscaler != null || playsOnAndroid;

  /// Starts the [Upscaler] (where mpv plays) and tells it the space the video fills: the whole screen or window.
  void _layoutUpscaler() {
    if (!player.supportsShaders) return;
    final upscaler = _upscaler ??= Upscaler(
      player,
      tier: offeredTier(Settings.upscale, tv: _upscaleTv),
      mobile: _mobileUpscaling,
      onSlow: (tier) => _hint(
        tier == Upscale.off
            ? "Upscaling turned off · this device can't keep up"
            : "Upscaling turned down to ${tier.label} · this device can't keep up",
        icon: Icons.auto_awesome_outlined,
      ),
    );
    upscaler.layout(
      MediaQuery.sizeOf(context),
      MediaQuery.devicePixelRatioOf(context),
    );
  }

  /// The tier shown as picked: the session's while mpv upscales, else the saved one.
  Upscale get _upscaleTier =>
      _upscaler?.tier ?? offeredTier(Settings.upscale, tv: _upscaleTv);

  /// Off, Fast or Quality (Off and Fast on Android TV), saved as the setting. Applied at once where mpv plays; on
  /// Android's Media3 a tier that upscales starts with the next video, and its label says so.
  _Choice<Upscale> get _upscaleChoice => _Choice(
    'Upscaling',
    {
      for (final t in upscaleTiers(tv: _upscaleTv))
        t: _upscaler == null && playsOnAndroid && t != Upscale.off
            ? '${t.label} · from the next video'
            : t.label,
    },
    _upscaleTier,
    (tier) async {
      Settings.upscale = tier;
      _refresh();
      if (_upscaler case final upscaler?) {
        await upscaler.setTier(tier);
      } else if (playsOnAndroid && tier != Upscale.off) {
        _hint(
          'Upscaling starts with the next video',
          icon: Icons.auto_awesome_outlined,
        );
      }
    },
  );

  String get _upscaleLabel => _upscaleTier.label;

  /// Desktop: a drop-down beside the speed's.
  Widget _upscaleMenu() => _choiceMenu(
    _upscaleChoice,
    tooltip: 'Upscaling · $_upscaleLabel',
    icon: Icons.auto_awesome_outlined,
  );

  /// Phone: a button beside the speed's; none where it isn't offered.
  Widget? _upscaleButton() => !_offersUpscaling
      ? null
      : TextButton.icon(
          style: _onVideo(TextButton.styleFrom(foregroundColor: Colors.white)),
          onPressed: () => _open(_upscaleChoice),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: Text(_upscaleLabel),
        );

  /// The player failed before the video loaded. In an Android upscaling session, where mpv may be what can't open
  /// it, the same episode reopens where it was asked to start, on Media3 for the rest of this player, and says so.
  /// False where there's nothing to fall back to: the server failed.
  bool _upscalingFellBack() {
    final stream = current;
    if (stream == null || !player.canFallBack) return false;
    final at = _startAt;
    _upscaler?.dispose();
    _upscaler = null;
    _hint(
      "Upscaling isn't available for this video",
      icon: Icons.auto_awesome_outlined,
    );
    () async {
      if (!await player.fallBack() || !mounted || current != stream) return;
      await _play(stream, at: at);
    }();
    return true;
  }
}
