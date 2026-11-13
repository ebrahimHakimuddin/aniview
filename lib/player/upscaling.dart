part of '../player.dart';

/// Anime4K upscaling in the player, where mpv plays (see [usesMediaKit]): the [Upscaler] that keeps the shaders
/// matched to the window, and its choice beside the speed's.
extension _Upscaling on _PlayerScreenState {
  /// Starts the [Upscaler] (mpv platforms only) and tells it the space the video fills: the whole screen or window.
  void _layoutUpscaler() {
    if (!usesMediaKit) return;
    final upscaler = _upscaler ??= Upscaler(
      player,
      tier: Settings.upscale,
      mobile: Platform.isIOS,
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

  /// Off, Fast or Quality: saved as the setting and applied at once.
  _Choice<Upscale> get _upscaleChoice => _Choice(
    'Upscaling',
    {for (final t in Upscale.values) t: t.label},
    _upscaler?.tier ?? Settings.upscale,
    (tier) async {
      Settings.upscale = tier;
      _refresh();
      await _upscaler?.setTier(tier);
    },
  );

  String get _upscaleLabel => (_upscaler?.tier ?? Settings.upscale).label;

  /// Desktop: a drop-down beside the speed's.
  Widget _upscaleMenu() => _choiceMenu(
    _upscaleChoice,
    tooltip: 'Upscaling · $_upscaleLabel',
    icon: Icons.auto_awesome_outlined,
  );

  /// Phone (iOS): a button beside the speed's; none where mpv doesn't play.
  Widget? _upscaleButton() => _upscaler == null
      ? null
      : TextButton.icon(
          style: _onVideo(TextButton.styleFrom(foregroundColor: Colors.white)),
          onPressed: () => _open(_upscaleChoice),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: Text(_upscaleLabel),
        );
}
