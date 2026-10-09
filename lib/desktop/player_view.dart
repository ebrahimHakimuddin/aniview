part of '../player.dart';

/// The desktop player's controls: a title bar along the top and, along the bottom, the seek bar over one row of
/// controls (play, volume, skip, and each choice a drop-down: subtitles, server, quality, speed). They come up when
/// the pointer moves and stay while it's over them; the keyboard and wheel (see [_onDesktopKey], [_pointer]) work
/// without them.
extension _DeskPlayer on _PlayerScreenState {
  Widget _deskOverlay(Duration position, bool loading) => Column(
    children: [
      _overBar(
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back  (Esc)',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(child: _titles(tv: false)),
                if (_episodes.length > 1)
                  IconButton(
                    tooltip: 'Episodes',
                    icon: const Icon(Icons.video_library_outlined),
                    onPressed: _openEpisodes,
                  ),
              ],
            ),
          ),
        ),
      ),
      const Spacer(),
      _overBar(
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xE6000000)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _timeline(position),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous episode',
                      onPressed: index > 0 ? () => _load(index - 1) : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton(
                      tooltip: player.state.playing
                          ? 'Pause  (Space)'
                          : 'Play  (Space)',
                      iconSize: 36,
                      onPressed: loading ? null : _click,
                      icon: Icon(
                        player.state.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next episode  (N)',
                      onPressed: hasNext ? () => _load(index + 1) : null,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const SizedBox(width: 8),
                    _volumeControl(),
                    const SizedBox(width: 12),
                    _skipButton(position),
                    const Spacer(),
                    if (_hasSubtitles) _subtitleMenu(),
                    if (_hasAudios) _audioMenu(),
                    if (_canSwitchServer) _serverMenu(),
                    if (_qualities.length > 1) _qualityMenu(),
                    _speedMenu(),
                    _fitButton(),
                    IconButton(
                      tooltip: 'Open in another app',
                      icon: const Icon(Icons.open_in_new_rounded),
                      onPressed: current == null ? null : _openExternal,
                    ),
                    IconButton(
                      tooltip: 'Fullscreen  (F)',
                      icon: const Icon(Icons.fullscreen_rounded),
                      onPressed: _toggleFullscreen,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  /// [bar] keeps the controls up while the pointer rests on it.
  Widget _overBar(Widget bar) => MouseRegion(
    onEnter: (_) => _overControls = true,
    onExit: (_) {
      _overControls = false;
      _scheduleHide();
    },
    child: bar,
  );

  Widget _volumeControl() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: volume == 0 ? 'Unmute  (M)' : 'Mute  (M)',
        icon: Icon(
          volume == 0
              ? Icons.volume_off_rounded
              : volume < .5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
        ),
        onPressed: () {
          if (volume > 0) _beforeMute = volume;
          _setVolume(volume > 0 ? 0 : _beforeMute);
        },
      ),
      SizedBox(
        width: 96,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbColor: Colors.white,
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: volume,
            onChanged: (v) {
              _set(() => volume = v);
              player.setVolume(v).ignore();
            },
          ),
        ),
      ),
    ],
  );

  /// A drop-down of [choice]'s options over an [icon], the selected one ticked.
  Widget _choiceMenu<T>(
    _Choice<T> choice, {
    required String tooltip,
    required IconData icon,
  }) => PopupMenuButton<T>(
    tooltip: tooltip,
    icon: Icon(icon),
    // Snaps open: the long grow-in feels slow with a mouse, and janks over a playing video.
    popUpAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 90),
      reverseDuration: Duration(milliseconds: 60),
    ),
    // The controls stay up while a menu is open, rather than fading out from under it.
    onOpened: () => _hideTimer?.cancel(),
    onCanceled: _scheduleHide,
    onSelected: (value) {
      _scheduleHide();
      choice.pick(value);
    },
    itemBuilder: (_) => [
      for (final MapEntry(:key, :value) in choice.options.entries)
        CheckedPopupMenuItem<T>(
          value: key,
          checked: key == choice.selected,
          child: Text(value),
        ),
    ],
  );

  Widget _subtitleMenu() => _choiceMenu(
    _subtitleChoice,
    tooltip: 'Subtitles · $subtitle',
    icon: subtitle == 'Off'
        ? Icons.subtitles_off_outlined
        : Icons.subtitles_outlined,
  );

  Widget _audioMenu() => _choiceMenu(
    _audioChoice,
    tooltip: 'Audio · ${audio ?? 'Auto'}',
    icon: Icons.audiotrack_outlined,
  );

  Widget _serverMenu() => _choiceMenu(
    _serverChoice,
    tooltip: 'Server · ${current!.label}',
    icon: Icons.dns_outlined,
  );

  Widget _qualityMenu() => _choiceMenu(
    _qualityChoice,
    tooltip: 'Quality · $_qualityLabel',
    icon: Icons.high_quality_rounded,
  );

  Widget _speedMenu() => _choiceMenu(
    _speedChoice,
    tooltip: 'Speed · $rate×  ( [ and ] )',
    icon: Icons.speed_rounded,
  );
}
